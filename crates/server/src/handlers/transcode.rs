use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    body::Body,
    extract::{Path as AxumPath, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use uuid::Uuid;

use crate::state::{AppState, TranscodeSession};
use crate::types::StartTranscodeBody;

/// POST /api/watch/transcode  {"url": "<flv-stream-url>"}
///
/// Starts an FFmpeg FLV→HLS transcode session.  If a session for this URL is
/// already running, the existing session is reused.  FFmpeg opens ONE direct
/// connection to the CDN URL — critical for Huya/Tengine which reject any
/// second concurrent connection from the same IP.
///
/// Waits up to 5 s for FFmpeg to produce the initial playlist before returning.
pub(crate) async fn start_transcode(
    State(state): State<AppState>,
    axum::Json(body): axum::Json<StartTranscodeBody>,
) -> impl IntoResponse {
    if !body.url.starts_with("http://") && !body.url.starts_with("https://") {
        return (
            StatusCode::BAD_REQUEST,
            axum::Json(serde_json::json!({"detail": "Invalid URL"})),
        )
            .into_response();
    }

    {
        let map = state.transcodes.read().await;
        if let Some(session) = map.get(&body.url) {
            session.touch();
            let id = session.id.clone();
            return axum::Json(serde_json::json!({
                "id": id,
                "playlist": format!("/api/watch/transcode/{id}/index.m3u8"),
            }))
            .into_response();
        }
    }

    let id = Uuid::new_v4().to_string();
    let tmp_dir = std::env::temp_dir().join(format!("transcode_{}", id));
    if let Err(e) = tokio::fs::create_dir_all(&tmp_dir).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            axum::Json(serde_json::json!({"detail": format!("tmpdir: {e}")})),
        )
            .into_response();
    }

    let seg_pattern = tmp_dir.join("seg_%05d.ts").to_string_lossy().into_owned();
    let playlist_path = tmp_dir.join("index.m3u8").to_string_lossy().into_owned();

    let child = tokio::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "warning",
            "-user_agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "-i",
            &body.url,
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-ar",
            "44100",
            "-f",
            "hls",
            "-hls_time",
            "2",
            "-hls_list_size",
            "6",
            "-hls_flags",
            "delete_segments+append_list",
            "-hls_segment_filename",
            &seg_pattern,
            &playlist_path,
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();

    let child = match child {
        Ok(c) => c,
        Err(e) => {
            let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(serde_json::json!({"detail": format!("ffmpeg spawn: {e}")})),
            )
                .into_response();
        }
    };

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let session = Arc::new(TranscodeSession {
        id: id.clone(),
        source_url: body.url.clone(),
        tmp_dir: tmp_dir.clone(),
        child: tokio::sync::Mutex::new(Some(child)),
        last_accessed: std::sync::atomic::AtomicU64::new(now_secs),
    });

    state
        .transcodes
        .write()
        .await
        .insert(body.url.clone(), session.clone());

    // Wait up to 5 s for FFmpeg to produce the first index.m3u8 with ≥1 segment.
    let m3u8_path = tmp_dir.join("index.m3u8");
    let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() >= deadline {
            break;
        }
        if let Ok(content) = tokio::fs::read_to_string(&m3u8_path).await {
            if content.contains("#EXTINF") {
                break;
            }
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;
    }

    axum::Json(serde_json::json!({
        "id": id,
        "playlist": format!("/api/watch/transcode/{id}/index.m3u8"),
    }))
    .into_response()
}

/// GET /api/watch/transcode/:id/index.m3u8
pub(crate) async fn transcode_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let session = {
        let map = state.transcodes.read().await;
        map.values().find(|s| s.id == id).cloned()
    };
    let Some(session) = session else {
        return (StatusCode::NOT_FOUND, "Transcode session not found").into_response();
    };
    session.touch();

    let m3u8_path = session.tmp_dir.join("index.m3u8");
    let content = match tokio::fs::read_to_string(&m3u8_path).await {
        Ok(c) => c,
        Err(_) => {
            return Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")
                .header(header::CACHE_CONTROL, "no-store")
                .body(Body::from(
                    "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n",
                ))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
        }
    };

    let rewritten: String = content
        .lines()
        .map(|line| {
            let t = line.trim();
            if !t.is_empty() && !t.starts_with('#') && t.ends_with(".ts") {
                let filename = std::path::Path::new(t)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or(t);
                format!("/api/watch/transcode/{id}/{filename}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from(rewritten))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// GET /api/watch/transcode/:id/:seg  — serve a .ts segment from the tmp dir.
pub(crate) async fn transcode_segment(
    State(state): State<AppState>,
    AxumPath((id, seg)): AxumPath<(String, String)>,
) -> impl IntoResponse {
    if seg.contains('/') || seg.contains("..") {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let session = {
        let map = state.transcodes.read().await;
        map.values().find(|s| s.id == id).cloned()
    };
    let Some(session) = session else {
        return StatusCode::NOT_FOUND.into_response();
    };
    session.touch();

    let seg_path = session.tmp_dir.join(&seg);
    match tokio::fs::read(&seg_path).await {
        Ok(bytes) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "video/mp2t")
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from(bytes))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

/// DELETE /api/watch/transcode/:id  — stop FFmpeg and remove tmp files.
pub(crate) async fn stop_transcode(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let session = {
        let mut map = state.transcodes.write().await;
        if let Some(key) = map
            .values()
            .find(|s| s.id == id)
            .map(|s| s.source_url.clone())
        {
            map.remove(&key)
        } else {
            None
        }
    };
    match session {
        Some(s) => {
            s.kill().await;
            StatusCode::NO_CONTENT.into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
