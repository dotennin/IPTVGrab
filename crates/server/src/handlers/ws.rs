use std::collections::HashSet;
use std::io::SeekFrom;

use axum::{
    body::Body,
    extract::{Path as AxumPath, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::helpers::{
    build_preview_master_m3u8, build_preview_media_playlist, contiguous_segments,
    preview_audio_dir, preview_audio_map_uri, preview_manifest_response, preview_map_uri,
    preview_segment_content_type, preview_task_context, save_preview_sections, scan_sections_async,
    serve_preview_file,
};
use crate::state::AppState;

pub(crate) async fn ws_task_handler(
    ws: axum::extract::ws::WebSocketUpgrade,
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if state.auth_password.is_some() {
        let cookie = headers
            .get(header::COOKIE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let token = cookie
            .split(';')
            .find_map(|p| p.trim().strip_prefix("session="))
            .unwrap_or("");
        let sessions = state.sessions.read().await;
        if !sessions.contains(token) {
            drop(sessions);
            return StatusCode::UNAUTHORIZED.into_response();
        }
    }
    ws.on_upgrade(move |socket| handle_ws_task(socket, state, task_id))
}

async fn handle_ws_task(
    mut socket: axum::extract::ws::WebSocket,
    state: AppState,
    task_id: String,
) {
    use axum::extract::ws::Message;

    let snapshot = {
        let tasks = state.tasks.read().await;
        tasks
            .get(&task_id)
            .and_then(|t| serde_json::to_string(t).ok())
    };
    let Some(snap) = snapshot else {
        let _ = socket.send(Message::Close(None)).await;
        return;
    };
    if socket.send(Message::Text(snap.clone())).await.is_err() {
        return;
    }

    let is_terminal = state
        .tasks
        .read()
        .await
        .get(&task_id)
        .map(|t| {
            matches!(
                t.status.as_str(),
                "completed" | "failed" | "cancelled" | "interrupted"
            )
        })
        .unwrap_or(true);
    if is_terminal {
        let _ = socket.send(Message::Close(None)).await;
        return;
    }

    let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(32);
    state
        .ws_subs
        .lock()
        .await
        .entry(task_id.clone())
        .or_default()
        .push(tx);

    let terminal_statuses: HashSet<&str> = ["completed", "failed", "cancelled", "interrupted"]
        .iter()
        .copied()
        .collect();

    loop {
        tokio::select! {
            msg = rx.recv() => {
                match msg {
                    Some(json) => {
                        let is_done = serde_json::from_str::<serde_json::Value>(&json)
                            .ok()
                            .and_then(|v| v.get("status").and_then(|s| s.as_str()).map(|s| terminal_statuses.contains(s)))
                            .unwrap_or(false);
                        if socket.send(Message::Text(json)).await.is_err() { break; }
                        if is_done { break; }
                    }
                    None => break,
                }
            }
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(25)) => {
                if socket.send(Message::Text(r#"{"type":"ping"}"#.into())).await.is_err() { break; }
            }
        }
    }
    let _ = socket.send(Message::Close(None)).await;
}

pub(crate) async fn preview_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur) = match preview_task_context(&task) {
        Ok(context) => context,
        Err(error) => return error.into_response(),
    };

    let video_segs = contiguous_segments(&tmpdir, &seg_ext);
    if video_segs.is_empty() {
        return (StatusCode::NOT_FOUND, "No segments yet".to_string()).into_response();
    }

    let audio_dir = preview_audio_dir(&tmpdir);
    let audio_segs = contiguous_segments(&audio_dir, &seg_ext);
    if !audio_segs.is_empty() {
        return preview_manifest_response(build_preview_master_m3u8(&task_id));
    }

    let sections = scan_sections_async(tmpdir.clone(), seg_ext.clone()).await;
    save_preview_sections(&tmpdir, &sections).await;
    let first_idx = sections.first().map(|s| s.start_idx).unwrap_or(0);
    use crate::helpers::build_m3u8;
    preview_manifest_response(build_m3u8(
        &video_segs[first_idx..],
        target_dur,
        &format!("/api/tasks/{task_id}/seg"),
        preview_map_uri(&task, &tmpdir, &task_id).as_deref(),
        &sections,
    ))
}

pub(crate) async fn preview_video_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur) = match preview_task_context(&task) {
        Ok(context) => context,
        Err(error) => return error.into_response(),
    };

    match build_preview_media_playlist(
        tmpdir.clone(),
        seg_ext.clone(),
        target_dur,
        format!("/api/tasks/{task_id}/seg"),
        preview_map_uri(&task, &tmpdir, &task_id),
    )
    .await
    {
        Ok(body) => preview_manifest_response(body),
        Err(error) => error.into_response(),
    }
}

pub(crate) async fn preview_audio_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur) = match preview_task_context(&task) {
        Ok(context) => context,
        Err(error) => return error.into_response(),
    };
    let audio_dir = preview_audio_dir(&tmpdir);

    match build_preview_media_playlist(
        audio_dir.clone(),
        seg_ext.clone(),
        target_dur,
        format!("/api/tasks/{task_id}/audio"),
        preview_audio_map_uri(&task, &tmpdir, &task_id),
    )
    .await
    {
        Ok(body) => preview_manifest_response(body),
        Err(error) => error.into_response(),
    }
}

pub(crate) async fn serve_segment(
    State(state): State<AppState>,
    AxumPath((task_id, filename)): AxumPath<(String, String)>,
) -> impl IntoResponse {
    serve_preview_file(
        state,
        task_id,
        filename.clone(),
        None,
        preview_segment_content_type(&filename, false),
    )
    .await
}

pub(crate) async fn serve_audio_segment(
    State(state): State<AppState>,
    AxumPath((task_id, filename)): AxumPath<(String, String)>,
) -> impl IntoResponse {
    serve_preview_file(
        state,
        task_id,
        filename.clone(),
        Some("audio"),
        preview_segment_content_type(&filename, true),
    )
    .await
}

pub(crate) async fn serve_download(
    State(state): State<AppState>,
    AxumPath(filename): AxumPath<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let path = state.downloads_dir.join(&filename);
    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(mut file) = tokio::fs::File::open(&path).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Ok(meta) = file.metadata().await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let size = meta.len();

    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| parse_byte_range(v, size));

    let (status, start, end) = match range {
        Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end),
        None => (StatusCode::OK, 0, size.saturating_sub(1)),
    };

    if size == 0 {
        return (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "video/mp4".to_string()),
                (header::ACCEPT_RANGES, "bytes".to_string()),
                (header::CONTENT_LENGTH, "0".to_string()),
                (
                    header::CONTENT_DISPOSITION,
                    format!("inline; filename=\"{filename}\""),
                ),
            ],
            Vec::<u8>::new(),
        )
            .into_response();
    }

    if end < start || start >= size {
        return (
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{size}"))],
        )
            .into_response();
    }

    let len = end - start + 1;
    if file.seek(SeekFrom::Start(start)).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    let limited = file.take(len);
    let stream = ReaderStream::new(limited);

    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "video/mp4")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, len.to_string())
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{filename}\""),
        );
    if status == StatusCode::PARTIAL_CONTENT {
        builder = builder.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }

    builder
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

pub(crate) fn parse_byte_range(range: &str, size: u64) -> Option<(u64, u64)> {
    let spec = range.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (start_raw, end_raw) = spec.split_once('-')?;

    if size == 0 {
        return None;
    }

    if start_raw.is_empty() {
        let suffix_len: u64 = end_raw.parse().ok()?;
        if suffix_len == 0 {
            return None;
        }
        let len = suffix_len.min(size);
        return Some((size - len, size - 1));
    }

    let start: u64 = start_raw.parse().ok()?;
    if start >= size {
        return None;
    }

    let end = if end_raw.is_empty() {
        size - 1
    } else {
        end_raw.parse::<u64>().ok()?.min(size - 1)
    };

    if end < start {
        return None;
    }

    Some((start, end))
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_byte_range_handles_common_forms() {
        assert_eq!(parse_byte_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_byte_range("bytes=100-", 1000), Some((100, 999)));
        assert_eq!(parse_byte_range("bytes=-50", 1000), Some((950, 999)));
        assert_eq!(parse_byte_range("bytes=1000-1001", 1000), None);
    }

    #[test]
    fn parse_byte_range_rejects_when_size_is_zero() {
        assert_eq!(parse_byte_range("bytes=0-99", 0), None);
    }

    #[test]
    fn parse_byte_range_handles_suffix_larger_than_size() {
        assert_eq!(parse_byte_range("bytes=-2000", 1000), Some((0, 999)));
    }

    #[test]
    fn parse_byte_range_returns_none_for_inverted_range() {
        assert_eq!(parse_byte_range("bytes=500-100", 1000), None);
    }

    #[test]
    fn parse_byte_range_clamps_end_to_last_byte() {
        assert_eq!(parse_byte_range("bytes=0-9999", 1000), Some((0, 999)));
    }

    #[test]
    fn parse_byte_range_rejects_missing_bytes_prefix() {
        assert_eq!(parse_byte_range("0-99", 1000), None);
    }

    #[test]
    fn parse_byte_range_handles_single_byte() {
        assert_eq!(parse_byte_range("bytes=0-0", 1000), Some((0, 0)));
        assert_eq!(parse_byte_range("bytes=999-999", 1000), Some((999, 999)));
    }

    #[test]
    fn parse_byte_range_open_start_suffix_zero_is_none() {
        assert_eq!(parse_byte_range("bytes=-0", 1000), None);
    }
}
