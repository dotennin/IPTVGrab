use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use tokio::sync::Semaphore;

use crate::state::AppState;
use crate::types::HealthEntry;

pub(crate) async fn get_health_check(State(state): State<AppState>) -> impl IntoResponse {
    let hs = state.health_state.read().await.clone();
    let cache = state.health_cache.read().await.clone();
    Json(serde_json::json!({
        "running": hs.running,
        "total": hs.total,
        "done": hs.done,
        "started_at": hs.started_at,
        "cache": cache,
    }))
}

#[derive(Deserialize, Default)]
pub(crate) struct HealthCheckQuery {
    #[serde(default)]
    pub deep: bool,
}

/// Deduplicate URLs, mark `running: true` immediately, then spawn HTTP checks
/// in the background.  Skips silently if a check is already running.
pub(crate) async fn trigger_health_check(state: AppState, urls: Vec<String>, deep: bool) {
    {
        let hs = state.health_state.read().await;
        if hs.running {
            return;
        }
    }
    let mut seen = std::collections::HashSet::new();
    let deduped: Vec<String> = urls
        .into_iter()
        .filter(|u| !u.is_empty() && seen.insert(u.clone()))
        .collect();
    if deduped.is_empty() {
        return;
    }
    let total = deduped.len();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    *state.health_state.write().await = crate::types::HealthState {
        running: true,
        total,
        done: 0,
        started_at: now,
    };
    tokio::spawn(async move {
        let sem = Arc::new(Semaphore::new(50));
        let mut handles = Vec::new();
        for url in deduped {
            let permit = sem.clone().acquire_owned().await.unwrap();
            let sc = state.clone();
            let u = url.clone();
            handles.push(tokio::spawn(async move {
                let entry = if deep {
                    check_url_deep(&u).await
                } else {
                    check_url_quick(&u).await
                };
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs_f64();
                sc.health_cache
                    .write()
                    .await
                    .insert(u, HealthEntry { checked_at: now, ..entry });
                sc.health_state.write().await.done += 1;
                drop(permit);
            }));
        }
        for h in handles {
            let _ = h.await;
        }
        state.health_state.write().await.running = false;
        state.save_health_cache().await;
    });
}

pub(crate) async fn post_health_check(
    State(state): State<AppState>,
    Query(query): Query<HealthCheckQuery>,
) -> impl IntoResponse {
    {
        let hs = state.health_state.read().await;
        if hs.running {
            return (
                StatusCode::CONFLICT,
                Json(serde_json::json!({"detail":"Already running"})),
            )
                .into_response();
        }
    }

    let urls: Vec<String> = {
        let playlists = state.playlists.read().await;
        playlists
            .values()
            .flat_map(|p| p.channels.iter().map(|c| c.url.clone()))
            .collect()
    };
    let total = {
        let mut seen = std::collections::HashSet::new();
        urls.iter()
            .filter(|u| !u.is_empty() && seen.insert(*u))
            .count()
    };
    trigger_health_check(state, urls, query.deep).await;
    Json(serde_json::json!({"ok": true, "total": total, "deep": query.deep})).into_response()
}

/// Quick reachability check: any HTTP 2xx/3xx response = "ok".
async fn check_url_quick(url: &str) -> HealthEntry {
    let client = build_client(8);
    let start = Instant::now();
    let status = match client.get(url).send().await {
        Ok(r) if r.status().as_u16() < 400 => "ok",
        Ok(_) => "dead",
        Err(_) => "dead",
    };
    HealthEntry {
        status: status.into(),
        latency_ms: Some(start.elapsed().as_millis() as u32),
        checked_at: 0.0,
    }
}

/// Deep playability check:
/// 1. HTTP reachability (same as quick).
/// 2. For M3U8/M3U responses: reads up to 64 KB and validates the manifest
///    contains `#EXTM3U` plus at least one segment or variant entry.
///
/// Status values:
/// - `"playable"` — M3U8 manifest is valid and has segments/variants.
/// - `"ok"`       — HTTP reachable but not an M3U8 (e.g. TS stream).
/// - `"invalid"`  — HTTP reachable but M3U8 content is malformed/empty.
/// - `"dead"`     — Unreachable or HTTP error.
async fn check_url_deep(url: &str) -> HealthEntry {
    let client = build_client(12);
    let start = Instant::now();

    let resp = match client.get(url).send().await {
        Ok(r) if r.status().as_u16() < 400 => r,
        Ok(_) => {
            return HealthEntry {
                status: "dead".into(),
                latency_ms: Some(start.elapsed().as_millis() as u32),
                checked_at: 0.0,
            }
        }
        Err(_) => {
            return HealthEntry {
                status: "dead".into(),
                latency_ms: Some(start.elapsed().as_millis() as u32),
                checked_at: 0.0,
            }
        }
    };

    let latency_ms = start.elapsed().as_millis() as u32;
    let ct = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();

    let is_m3u8_url = url.contains(".m3u8") || url.contains(".m3u");
    let is_m3u8_ct = ct.contains("mpegurl") || ct.contains("x-mpegurl") || ct.contains("x-scpls");

    if !is_m3u8_url && !is_m3u8_ct {
        // Non-M3U8 (e.g. raw TS, RTSP, etc.) — HTTP reachable is good enough.
        return HealthEntry {
            status: "ok".into(),
            latency_ms: Some(latency_ms),
            checked_at: 0.0,
        };
    }

    // Read up to 64 KB to validate manifest.
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(_) => {
            return HealthEntry {
                status: "invalid".into(),
                latency_ms: Some(latency_ms),
                checked_at: 0.0,
            }
        }
    };
    let body = String::from_utf8_lossy(&bytes[..bytes.len().min(65536)]);
    let status = validate_m3u8_content(&body);
    HealthEntry {
        status: status.into(),
        latency_ms: Some(latency_ms),
        checked_at: 0.0,
    }
}

/// Returns `"playable"`, `"ok"`, or `"invalid"` based on M3U8 content.
fn validate_m3u8_content(body: &str) -> &'static str {
    if !body.trim_start().starts_with("#EXTM3U") {
        return "invalid";
    }
    // Has at least one media segment (VOD or live)
    let has_segment = body.contains("#EXTINF:");
    // Or a master/variant playlist
    let has_variant = body.contains("#EXT-X-STREAM-INF:") || body.contains("#EXT-X-MEDIA:");
    if has_segment || has_variant {
        "playable"
    } else {
        // Has #EXTM3U header but no content — possibly empty or unsupported
        "invalid"
    }
}

fn build_client(timeout_secs: u64) -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (compatible; MediaNest-checker/1.0)")
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .unwrap_or_default()
}

