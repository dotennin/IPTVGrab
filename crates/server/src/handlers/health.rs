use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json},
};
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

/// Deduplicate URLs, mark `running: true` immediately, then spawn HTTP checks
/// in the background.  Skips silently if a check is already running.
pub(crate) async fn trigger_health_check(state: AppState, urls: Vec<String>) {
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
                let status = check_url(&u).await;
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs_f64();
                sc.health_cache
                    .write()
                    .await
                    .insert(u, HealthEntry { status, checked_at: now });
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

pub(crate) async fn post_health_check(State(state): State<AppState>) -> impl IntoResponse {
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
    trigger_health_check(state, urls).await;
    Json(serde_json::json!({"ok": true, "total": total})).into_response()
}

async fn check_url(url: &str) -> String {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (compatible; IPTV-checker/1.0)")
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .unwrap_or_default();
    match client.get(url).send().await {
        Ok(r) if r.status().as_u16() < 400 => "ok".into(),
        Ok(_) => "dead".into(),
        Err(_) => "dead".into(),
    }
}
