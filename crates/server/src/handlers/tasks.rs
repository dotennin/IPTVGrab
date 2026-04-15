use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use m3u8_core::{DownloadConfig, DownloadError, Downloader, ProgressEvent, Quality};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::state::AppState;
use crate::types::{DownloadRequest, ParseRequest, Task};

pub(crate) async fn parse_stream(
    State(_state): State<AppState>,
    Json(body): Json<ParseRequest>,
) -> impl IntoResponse {
    if body.url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"URL required"})),
        )
            .into_response();
    }
    let config = DownloadConfig {
        url: body.url.clone(),
        headers: body.headers,
        ..Default::default()
    };
    let dl = Downloader::new(config);
    match dl.parse().await {
        Ok(info) => Json(serde_json::to_value(&info).unwrap()).into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail": e.to_string()})),
        )
            .into_response(),
    }
}

pub(crate) async fn start_download(
    State(state): State<AppState>,
    Json(body): Json<DownloadRequest>,
) -> impl IntoResponse {
    let task_id = Uuid::new_v4().to_string();
    let quality = match body.quality.as_str() {
        "worst" => Quality::Worst,
        s if s.parse::<usize>().is_ok() => Quality::Index(s.parse().unwrap()),
        _ => Quality::Best,
    };
    let config = DownloadConfig {
        url: body.url.clone(),
        headers: body.headers.clone(),
        output_dir: state.downloads_dir.clone(),
        output_name: body.output_name.clone(),
        quality,
        concurrency: body.concurrency,
        task_id: task_id.clone(),
        ..Default::default()
    };

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();

    let task = Task {
        id: task_id.clone(),
        url: body.url.clone(),
        status: "queued".into(),
        progress: 0,
        total: 0,
        downloaded: 0,
        failed: 0,
        speed_mbps: 0.0,
        bytes_downloaded: 0,
        output: None,
        size: 0,
        error: None,
        created_at: now,
        req_headers: body.headers,
        output_name: body.output_name,
        quality: body.quality,
        concurrency: body.concurrency,
        tmpdir: None,
        is_cmaf: None,
        seg_ext: None,
        target_duration: None,
        duration_sec: None,
        recorded_segments: None,
        elapsed_sec: None,
        task_type: None,
    };

    state.tasks.write().await.insert(task_id.clone(), task);
    state.save_tasks().await;

    let dl = Arc::new(Downloader::new(config));
    state
        .downloaders
        .write()
        .await
        .insert(task_id.clone(), dl.clone());

    let state_clone = state.clone();
    let tid = task_id.clone();
    tokio::spawn(async move {
        run_download(state_clone, tid, dl).await;
    });

    Json(serde_json::json!({"task_id": task_id}))
}

pub(crate) async fn run_download(
    state: AppState,
    task_id: String,
    dl: Arc<Downloader>,
) {
    let (tx, mut rx) = mpsc::channel::<ProgressEvent>(64);

    let state_clone = state.clone();
    let tid = task_id.clone();
    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let json = {
                let mut tasks = state_clone.tasks.write().await;
                if let Some(task) = tasks.get_mut(&tid) {
                    let already_terminal = matches!(
                        task.status.as_str(),
                        "cancelled" | "completed" | "failed" | "interrupted" | "paused"
                    );
                    if !already_terminal {
                        apply_event(task, event.clone());
                    }
                }
                tasks.get(&tid).and_then(|t| serde_json::to_string(t).ok())
            };
            if let Some(j) = json {
                let subs = state_clone.ws_subs.lock().await;
                if let Some(list) = subs.get(&tid) {
                    for sender in list {
                        let _ = sender.try_send(j.clone());
                    }
                }
            }
            match &event {
                ProgressEvent::Completed { .. }
                | ProgressEvent::Failed { .. }
                | ProgressEvent::Cancelled => {
                    state_clone.save_tasks().await;
                }
                ProgressEvent::Downloading { .. } | ProgressEvent::Recording { .. } => {}
                _ => {
                    state_clone.save_tasks().await;
                }
            }
        }
    });

    {
        let mut tasks = state.tasks.write().await;
        if let Some(t) = tasks.get_mut(&task_id) {
            t.status = "downloading".into();
        }
    }

    if let Err(e) = dl.download(tx).await {
        if matches!(e, DownloadError::Paused) {
            let mut tasks = state.tasks.write().await;
            if let Some(t) = tasks.get_mut(&task_id) {
                if !matches!(t.status.as_str(), "cancelled" | "completed" | "interrupted") {
                    t.status = "paused".into();
                    t.error = None;
                }
            }
            drop(tasks);
            state.save_tasks().await;
        } else if !matches!(e, DownloadError::Cancelled) && !dl.is_cancelled() {
            let mut tasks = state.tasks.write().await;
            if let Some(t) = tasks.get_mut(&task_id) {
                if !matches!(t.status.as_str(), "cancelled" | "completed" | "interrupted") {
                    t.status = "failed".into();
                    t.error = Some(e.to_string());
                }
            }
            drop(tasks);
            state.save_tasks().await;
        }
    }

    state.downloaders.write().await.remove(&task_id);
}

pub(crate) fn apply_event(task: &mut Task, event: ProgressEvent) {
    match event {
        ProgressEvent::Downloading {
            total,
            downloaded,
            failed,
            progress,
            speed_mbps,
            bytes_downloaded,
            tmpdir,
            is_cmaf,
            seg_ext,
            target_duration,
        } => {
            task.status = "downloading".into();
            task.total = total;
            task.downloaded = downloaded;
            task.failed = failed;
            task.progress = progress;
            task.speed_mbps = speed_mbps;
            task.bytes_downloaded = bytes_downloaded;
            task.tmpdir = Some(tmpdir);
            task.is_cmaf = Some(is_cmaf);
            task.seg_ext = Some(seg_ext);
            task.target_duration = Some(target_duration);
        }
        ProgressEvent::Recording {
            recorded_segments,
            bytes_downloaded,
            speed_mbps,
            elapsed_sec,
            tmpdir,
            is_cmaf,
            seg_ext,
            target_duration,
        } => {
            task.status = "recording".into();
            task.recorded_segments = Some(recorded_segments);
            task.bytes_downloaded = bytes_downloaded;
            task.speed_mbps = speed_mbps;
            task.elapsed_sec = Some(elapsed_sec);
            task.tmpdir = Some(tmpdir);
            task.is_cmaf = Some(is_cmaf);
            task.seg_ext = Some(seg_ext);
            task.target_duration = Some(target_duration);
        }
        ProgressEvent::Merging { progress } => {
            task.status = "merging".into();
            task.progress = progress;
            task.error = None;
        }
        ProgressEvent::Completed {
            output,
            size,
            duration_sec,
        } => {
            task.status = "completed".into();
            task.progress = 100;
            task.output = Some(output);
            task.size = size;
            task.duration_sec = Some(duration_sec);
            task.error = None;
        }
        ProgressEvent::Failed { error } => {
            task.status = "failed".into();
            task.error = Some(error);
        }
        ProgressEvent::Cancelled => {
            task.status = "cancelled".into();
            task.error = None;
        }
        ProgressEvent::Paused => {
            task.status = "paused".into();
            task.error = None;
        }
    }
}

pub(crate) async fn list_tasks(State(state): State<AppState>) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let mut list: Vec<Task> = tasks.values().cloned().collect();
    list.sort_by(|a, b| b.created_at.partial_cmp(&a.created_at).unwrap());
    Json(list)
}

pub(crate) async fn get_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    match tasks.get(&task_id) {
        Some(t) => Json(serde_json::to_value(t).unwrap()).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response(),
    }
}

pub(crate) async fn cancel_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let mut tasks = state.tasks.write().await;
    let Some(task) = tasks.get_mut(&task_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };

    let status = task.status.clone();
    if status == "recording" {
        task.status = "stopping".into();
        task.error = None;
        drop(tasks);
        if let Some(dl) = state.downloaders.read().await.get(&task_id) {
            dl.stop();
        }
        state.save_tasks().await;
        return Json(serde_json::json!({"status":"stopping"})).into_response();
    }

    if !matches!(
        status.as_str(),
        "completed" | "failed" | "cancelled" | "interrupted"
    ) {
        task.status = "cancelled".into();
        task.error = None;
        drop(tasks);
        if let Some(dl) = state.downloaders.read().await.get(&task_id) {
            dl.cancel();
        }
        cleanup_tmpdir(&state, &task_id).await;
        state.save_tasks().await;
        return Json(serde_json::json!({"status":"cancelled"})).into_response();
    }

    let output = task.output.clone();
    tasks.remove(&task_id);
    drop(tasks);
    cleanup_tmpdir(&state, &task_id).await;
    if let Some(name) = output {
        let path = state.downloads_dir.join(name);
        let _ = tokio::fs::remove_file(path).await;
    }
    state.save_tasks().await;
    Json(serde_json::json!({"status":"deleted"})).into_response()
}

pub(crate) async fn cleanup_tmpdir(state: &AppState, task_id: &str) {
    let tmpdir = state
        .tasks
        .read()
        .await
        .get(task_id)
        .and_then(|t| t.tmpdir.clone());
    if let Some(dir) = tmpdir {
        let _ = tokio::fs::remove_dir_all(&dir).await;
        if let Some(t) = state.tasks.write().await.get_mut(task_id) {
            t.tmpdir = None;
        }
    }
}

pub(crate) async fn pause_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let mut tasks = state.tasks.write().await;
    let Some(task) = tasks.get_mut(&task_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    let status = task.status.clone();
    if !matches!(
        status.as_str(),
        "downloading" | "recording" | "queued" | "merging" | "stopping"
    ) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Task is not pausable in its current state"})),
        )
            .into_response();
    }
    task.status = "paused".into();
    task.error = None;
    drop(tasks);
    if let Some(dl) = state.downloaders.read().await.get(&task_id) {
        dl.pause();
    }
    state.save_tasks().await;
    Json(serde_json::json!({"status": "paused"})).into_response()
}

pub(crate) async fn resume_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    if !matches!(task.status.as_str(), "interrupted" | "failed" | "paused") {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Not resumable"})),
        )
            .into_response();
    }
    let quality = match task.quality.as_str() {
        "worst" => Quality::Worst,
        s if s.parse::<usize>().is_ok() => Quality::Index(s.parse().unwrap()),
        _ => Quality::Best,
    };
    let config = DownloadConfig {
        url: task.url.clone(),
        headers: task.req_headers.clone(),
        output_dir: state.downloads_dir.clone(),
        output_name: task.output_name.clone(),
        quality,
        concurrency: task.concurrency,
        task_id: task_id.clone(),
        base_elapsed_sec: task.elapsed_sec.unwrap_or(0),
        ..Default::default()
    };
    drop(tasks);
    {
        let mut tasks = state.tasks.write().await;
        if let Some(t) = tasks.get_mut(&task_id) {
            t.status = "queued".into();
            t.error = None;
        }
    }
    state.save_tasks().await;

    let dl = Arc::new(Downloader::new(config));
    state
        .downloaders
        .write()
        .await
        .insert(task_id.clone(), dl.clone());
    let state_clone = state.clone();
    let tid = task_id.clone();
    tokio::spawn(async move { run_download(state_clone, tid, dl).await });

    Json(serde_json::json!({"task_id": task_id, "status": "queued"})).into_response()
}

// ── Task action helpers ────────────────────────────────────────────────────────

pub(crate) fn make_task(id: &str, task: &Task, now: f64) -> Task {
    Task {
        id: id.to_string(),
        url: task.url.clone(),
        status: "queued".into(),
        progress: 0,
        total: 0,
        downloaded: 0,
        failed: 0,
        speed_mbps: 0.0,
        bytes_downloaded: 0,
        output: None,
        size: 0,
        error: None,
        created_at: now,
        req_headers: task.req_headers.clone(),
        output_name: task.output_name.clone(),
        quality: task.quality.clone(),
        concurrency: task.concurrency,
        tmpdir: None,
        is_cmaf: None,
        seg_ext: None,
        target_duration: None,
        duration_sec: None,
        recorded_segments: None,
        elapsed_sec: None,
        task_type: None,
    }
}

pub(crate) async fn spawn_task(state: &AppState, task_id: &str) {
    let (url, headers, quality_str, concurrency, output_name) = {
        let tasks = state.tasks.read().await;
        let t = tasks.get(task_id).cloned().unwrap();
        (t.url, t.req_headers, t.quality, t.concurrency, t.output_name)
    };
    let quality = match quality_str.as_str() {
        "worst" => Quality::Worst,
        s if s.parse::<usize>().is_ok() => Quality::Index(s.parse().unwrap()),
        _ => Quality::Best,
    };
    let config = DownloadConfig {
        url,
        headers,
        output_dir: state.downloads_dir.clone(),
        output_name,
        quality,
        concurrency,
        task_id: task_id.to_string(),
        ..Default::default()
    };
    let dl = Arc::new(Downloader::new(config));
    state
        .downloaders
        .write()
        .await
        .insert(task_id.to_string(), dl.clone());
    let state_clone = state.clone();
    let tid = task_id.to_string();
    tokio::spawn(async move { run_download(state_clone, tid, dl).await });
}

pub(crate) async fn recording_restart(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let task = {
        let tasks = state.tasks.read().await;
        match tasks.get(&task_id) {
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"Not found"})),
                )
                    .into_response()
            }
            Some(t) if t.status != "recording" => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Not recording"})),
                )
                    .into_response()
            }
            Some(t) => t.clone(),
        }
    };
    if let Some(dl) = state.downloaders.read().await.get(&task_id) {
        dl.cancel();
    }
    cleanup_tmpdir(&state, &task_id).await;
    state.tasks.write().await.remove(&task_id);
    state.downloaders.write().await.remove(&task_id);
    state.save_tasks().await;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let new_id = Uuid::new_v4().to_string();
    state
        .tasks
        .write()
        .await
        .insert(new_id.clone(), make_task(&new_id, &task, now));
    state.save_tasks().await;
    spawn_task(&state, &new_id).await;
    Json(serde_json::json!({"new_task_id": new_id, "url": task.url})).into_response()
}

pub(crate) async fn fork_recording(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let task = {
        let tasks = state.tasks.read().await;
        match tasks.get(&task_id) {
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"Not found"})),
                )
                    .into_response()
            }
            Some(t) if t.status != "recording" => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Not recording"})),
                )
                    .into_response()
            }
            Some(t) => t.clone(),
        }
    };
    if let Some(dl) = state.downloaders.read().await.get(&task_id) {
        dl.stop();
    }
    state
        .tasks
        .write()
        .await
        .get_mut(&task_id)
        .map(|t| t.status = "stopping".into());
    state.save_tasks().await;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let new_id = Uuid::new_v4().to_string();
    state
        .tasks
        .write()
        .await
        .insert(new_id.clone(), make_task(&new_id, &task, now));
    state.save_tasks().await;
    spawn_task(&state, &new_id).await;
    Json(serde_json::json!({"new_task_id": new_id, "url": task.url})).into_response()
}

pub(crate) async fn restart_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    {
        let tasks = state.tasks.read().await;
        match tasks.get(&task_id) {
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"Not found"})),
                )
                    .into_response()
            }
            Some(t)
                if !matches!(
                    t.status.as_str(),
                    "completed" | "failed" | "cancelled" | "interrupted"
                ) =>
            {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Cannot restart in current state"})),
                )
                    .into_response()
            }
            _ => {}
        }
    }
    cleanup_tmpdir(&state, &task_id).await;
    let output = state
        .tasks
        .read()
        .await
        .get(&task_id)
        .and_then(|t| t.output.clone());
    if let Some(name) = output {
        let _ = tokio::fs::remove_file(state.downloads_dir.join(name)).await;
    }
    {
        let mut tasks = state.tasks.write().await;
        if let Some(t) = tasks.get_mut(&task_id) {
            t.status = "queued".into();
            t.progress = 0;
            t.downloaded = 0;
            t.failed = 0;
            t.total = 0;
            t.bytes_downloaded = 0;
            t.speed_mbps = 0.0;
            t.output = None;
            t.size = 0;
            t.error = None;
            t.tmpdir = None;
        }
    }
    state.save_tasks().await;
    spawn_task(&state, &task_id).await;
    Json(serde_json::json!({"task_id": task_id, "status": "queued"})).into_response()
}
