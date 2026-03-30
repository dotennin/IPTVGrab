use std::collections::{HashMap, HashSet};
use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Once};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    body::Body,
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::{Path as AxumPath, Query, State},
    http::{header, HeaderMap, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Json, Response},
    routing::{delete, get, patch, post},
    Router,
};
use m3u8_core::{
    parser::resolve, DownloadConfig, DownloadError, Downloader, ProgressEvent,
    Quality,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::{mpsc, RwLock, Semaphore};
use tower_http::cors::{Any, CorsLayer};
use tower_http::services::ServeDir;
use tracing::info;
use url::form_urlencoded;
use uuid::Uuid;

// ── App State ─────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct AppState {
    tasks: Arc<RwLock<HashMap<String, Task>>>,
    downloaders: Arc<RwLock<HashMap<String, Arc<Downloader>>>>,
    downloads_dir: PathBuf,
    http_client: reqwest::Client,
    auth_password: Option<String>,
    sessions: Arc<RwLock<HashSet<String>>>,
    playlists: Arc<RwLock<HashMap<String, SavedPlaylist>>>,
    merged_config: Arc<RwLock<MergedConfig>>,
    health_cache: Arc<RwLock<HashMap<String, HealthEntry>>>,
    health_state: Arc<RwLock<HealthState>>,
    watch_cache: Arc<RwLock<HashMap<String, WatchCacheEntry>>>,
    ws_subs: Arc<tokio::sync::Mutex<HashMap<String, Vec<mpsc::Sender<String>>>>>,
}

impl AppState {
    async fn save_tasks(&self) {
        let path = self.downloads_dir.join("tasks.json");
        let tasks = self.tasks.read().await;
        let _ = tokio::fs::write(
            &path,
            serde_json::to_vec_pretty(&*tasks).unwrap_or_default(),
        )
        .await;
    }
    async fn save_playlists(&self) {
        let path = self.downloads_dir.join("playlists.json");
        let pl = self.playlists.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*pl).unwrap_or_default()).await;
    }
    async fn save_merged_config(&self) {
        let path = self.downloads_dir.join("merged_config.json");
        let mc = self.merged_config.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*mc).unwrap_or_default()).await;
    }
    async fn save_health_cache(&self) {
        let path = self.downloads_dir.join("health_cache.json");
        let hc = self.health_cache.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*hc).unwrap_or_default()).await;
    }
}

// ── Data types ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Task {
    id: String,
    url: String,
    status: String,
    progress: u8,
    total: usize,
    downloaded: usize,
    failed: usize,
    speed_mbps: f64,
    bytes_downloaded: u64,
    output: Option<String>,
    size: u64,
    error: Option<String>,
    created_at: f64,
    req_headers: HashMap<String, String>,
    output_name: Option<String>,
    quality: String,
    concurrency: usize,
    tmpdir: Option<String>,
    is_cmaf: Option<bool>,
    seg_ext: Option<String>,
    target_duration: Option<f64>,
    duration_sec: Option<f64>,
    recorded_segments: Option<usize>,
    elapsed_sec: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SavedPlaylist {
    id: String,
    name: String,
    url: Option<String>,
    channels: Vec<Channel>,
    created_at: f64,
    #[serde(default)]
    updated_at: f64,
    #[serde(default)]
    channel_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Channel {
    name: String,
    url: String,
    group: Option<String>,
    logo: Option<String>,
}

fn bool_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MergedConfig {
    groups: Vec<MergedGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MergedGroup {
    id: String,
    name: String,
    #[serde(default = "bool_true")]
    enabled: bool,
    #[serde(default)]
    custom: bool,
    channels: Vec<MergedChannel>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MergedChannel {
    id: String,
    name: String,
    url: String,
    #[serde(default = "bool_true")]
    enabled: bool,
    #[serde(default)]
    custom: bool,
    #[serde(default)]
    group: String,
    #[serde(default)]
    tvg_logo: String,
    #[serde(default)]
    source_playlist_id: Option<String>,
    #[serde(default)]
    source_playlist_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct HealthEntry {
    status: String,
    checked_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct HealthState {
    running: bool,
    total: usize,
    done: usize,
    started_at: f64,
}

#[derive(Debug, Clone)]
struct WatchCacheEntry {
    body: Vec<u8>,
    content_type: String,
    cache_control: String,
    expires_at: f64,
}

#[derive(Debug, Deserialize)]
struct WatchProxyQuery {
    url: String,
}

// ── Request/Response models ───────────────────────────────────────────────────

#[derive(Deserialize)]
struct ParseRequest {
    url: String,
    #[serde(default)]
    headers: HashMap<String, String>,
}

#[derive(Deserialize)]
struct DownloadRequest {
    url: String,
    #[serde(default)]
    headers: HashMap<String, String>,
    #[serde(default)]
    output_name: Option<String>,
    #[serde(default = "default_quality")]
    quality: String,
    #[serde(default = "default_concurrency")]
    concurrency: usize,
}

fn default_quality() -> String {
    "best".into()
}
fn default_concurrency() -> usize {
    8
}

#[derive(Deserialize)]
struct LoginRequest {
    password: String,
}

#[derive(Deserialize)]
struct AddPlaylistRequest {
    name: String,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    raw: Option<String>,
}

#[derive(Deserialize)]
struct EditPlaylistRequest {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    url: Option<String>,
}

#[derive(Deserialize)]
struct AddGroupRequest {
    name: String,
}

#[derive(Deserialize)]
struct AddChannelRequest {
    group_id: String,
    name: String,
    url: String,
    #[serde(default)]
    tvg_logo: String,
}

#[derive(Deserialize)]
struct EditChannelRequest {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    group: Option<String>,
}

#[derive(Deserialize)]
struct ClipRequest {
    start: f64,
    end: f64,
}

#[derive(Deserialize)]
struct LocalMergeCompleteRequest {
    filename: String,
    size: u64,
    #[serde(default)]
    duration_sec: Option<f64>,
}

// ── Auth middleware ───────────────────────────────────────────────────────────

async fn auth_middleware(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let _password = match &state.auth_password {
        None => return next.run(req).await,
        Some(p) => p.clone(),
    };

    let path = req.uri().path().to_string();
    if matches!(path.as_str(), "/login" | "/api/login" | "/api/logout")
        || path.ends_with(".js")
        || path.ends_with(".css")
        || path.ends_with(".ico")
        || path.ends_with(".png")
    {
        return next.run(req).await;
    }

    let cookie = req
        .headers()
        .get(header::COOKIE)
        .and_then(|c| c.to_str().ok())
        .unwrap_or("");

    let token = cookie
        .split(';')
        .find_map(|part| {
            let p = part.trim();
            p.strip_prefix("session=")
        })
        .unwrap_or("")
        .to_string();

    let sessions = state.sessions.read().await;
    if sessions.contains(&token) {
        drop(sessions);
        return next.run(req).await;
    }

    if path.starts_with("/api/") {
        (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"detail": "Unauthorized"})),
        )
            .into_response()
    } else {
        axum::response::Redirect::to("/login").into_response()
    }
}

// ── Handlers ──────────────────────────────────────────────────────────────────

async fn login_page() -> impl IntoResponse {
    axum::response::Redirect::to("/login.html")
}

async fn api_login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> impl IntoResponse {
    if let Some(ref pw) = state.auth_password {
        if body.password != *pw {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"detail": "Invalid password"})),
            )
                .into_response();
        }
    }
    let token = Uuid::new_v4().to_string();
    state.sessions.write().await.insert(token.clone());
    let mut response = Json(serde_json::json!({"status": "ok"})).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        format!("session={token}; Path=/; HttpOnly; SameSite=Lax")
            .parse()
            .unwrap(),
    );
    response
}

async fn api_logout(State(state): State<AppState>, req: Request<Body>) -> impl IntoResponse {
    let token = req
        .headers()
        .get(header::COOKIE)
        .and_then(|c| c.to_str().ok())
        .unwrap_or("")
        .split(';')
        .find_map(|p| p.trim().strip_prefix("session="))
        .unwrap_or("")
        .to_string();
    state.sessions.write().await.remove(&token);
    let mut resp = Json(serde_json::json!({"status": "ok"})).into_response();
    resp.headers_mut().insert(
        header::SET_COOKIE,
        "session=; Path=/; Max-Age=0".parse().unwrap(),
    );
    resp
}

async fn auth_status(State(state): State<AppState>) -> impl IntoResponse {
    Json(serde_json::json!({
        "auth_required": state.auth_password.is_some()
    }))
}

async fn parse_stream(
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

async fn start_download(
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
    };

    state.tasks.write().await.insert(task_id.clone(), task);
    state.save_tasks().await;

    let dl = Arc::new(Downloader::new(config));
    state
        .downloaders
        .write()
        .await
        .insert(task_id.clone(), dl.clone());

    // Spawn background download
    let state_clone = state.clone();
    let tid = task_id.clone();
    tokio::spawn(async move {
        run_download(state_clone, tid, dl).await;
    });

    Json(serde_json::json!({"task_id": task_id}))
}

async fn run_download(state: AppState, task_id: String, dl: Arc<Downloader>) {
    let (tx, mut rx) = mpsc::channel::<ProgressEvent>(64);

    // Task that drains progress events
    let state_clone = state.clone();
    let tid = task_id.clone();
    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let json = {
                let mut tasks = state_clone.tasks.write().await;
                if let Some(task) = tasks.get_mut(&tid) {
                    // Don't overwrite a terminal status (e.g. "cancelled" set by cancel_task)
                    // with a stale event from the still-running download.
                    let already_terminal = matches!(
                        task.status.as_str(),
                        "cancelled" | "completed" | "failed" | "interrupted"
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
        // Only mark as failed if not already in a terminal state (e.g. "cancelled" set
        // by cancel_task) and this wasn't a cancellation error.
        if !matches!(e, DownloadError::Cancelled) && !dl.is_cancelled() {
            let mut tasks = state.tasks.write().await;
            if let Some(t) = tasks.get_mut(&task_id) {
                // Don't overwrite terminal status set externally (e.g. cancel_task)
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

fn apply_event(task: &mut Task, event: ProgressEvent) {
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
    }
}

async fn list_tasks(State(state): State<AppState>) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let mut list: Vec<Task> = tasks.values().cloned().collect();
    list.sort_by(|a, b| b.created_at.partial_cmp(&a.created_at).unwrap());
    Json(list)
}

async fn get_task(
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

async fn cancel_task(
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

async fn cleanup_tmpdir(state: &AppState, task_id: &str) {
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

async fn resume_task(
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
    if !matches!(task.status.as_str(), "interrupted" | "failed") {
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

fn make_task(id: &str, task: &Task, now: f64) -> Task {
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
    }
}

async fn spawn_task(state: &AppState, task_id: &str) {
    let (url, headers, quality_str, concurrency, output_name) = {
        let tasks = state.tasks.read().await;
        let t = tasks.get(task_id).cloned().unwrap();
        (
            t.url,
            t.req_headers,
            t.quality,
            t.concurrency,
            t.output_name,
        )
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

async fn recording_restart(
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
    state
        .tasks
        .write()
        .await
        .get_mut(&task_id)
        .map(|t| t.status = "cancelled".into());
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

async fn fork_recording(
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

async fn restart_task(
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
    // Remove old output file
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

// ── Clip task ─────────────────────────────────────────────────────────────────

fn fmt_hms(secs: f64) -> String {
    let total = secs as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h:02}h{m:02}m{s:02}s")
    } else {
        format!("{m:02}m{s:02}s")
    }
}

async fn clip_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    Json(body): Json<ClipRequest>,
) -> impl IntoResponse {
    if body.start < 0.0 || body.end <= body.start || (body.end - body.start) < 0.5 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Invalid clip range (end must be ≥ start + 0.5 s)"})),
        )
            .into_response();
    }
    let task = {
        let tasks = state.tasks.read().await;
        match tasks.get(&task_id).cloned() {
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"Not found"})),
                )
                    .into_response()
            }
            Some(t) => t,
        }
    };
    let duration = body.end - body.start;
    let suffix = format!("{}-{}", fmt_hms(body.start), fmt_hms(body.end));

    // Ensure downloads_dir is absolute so ffmpeg paths are unambiguous
    let downloads_dir =
        std::fs::canonicalize(&state.downloads_dir).unwrap_or_else(|_| state.downloads_dir.clone());

    // Case 1: completed task — clip from the final MP4
    if task.status == "completed" {
        let output = match &task.output {
            Some(o) => o.clone(),
            None => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"No output file"})),
                )
                    .into_response()
            }
        };
        let input_path = downloads_dir.join(&output);
        if !input_path.exists() {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"Output file not found"})),
            )
                .into_response();
        }
        let stem = Path::new(&output)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let clip_name = format!("{stem}_clip_{suffix}.mp4");
        let clip_path = downloads_dir.join(&clip_name);
        let out = tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-ss",
                &body.start.to_string(),
                "-i",
                &input_path.to_string_lossy(),
                "-t",
                &duration.to_string(),
                "-c",
                "copy",
                "-movflags",
                "+faststart",
                &clip_path.to_string_lossy(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .output()
            .await;
        return match out {
            Ok(o) if o.status.success() => {
                Json(serde_json::json!({"filename": clip_name})).into_response()
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr)
                    .lines()
                    .last()
                    .unwrap_or("")
                    .to_string();
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"detail": format!("ffmpeg clip failed: {stderr}")})),
                )
                    .into_response()
            }
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": format!("ffmpeg not found: {e}")})),
            )
                .into_response(),
        };
    }

    // Case 2: in-progress task — clip from tmpdir segments
    let tmpdir = match task.tmpdir.as_deref().filter(|d| Path::new(d).exists()) {
        Some(d) => PathBuf::from(d),
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail":"Task cannot be clipped in its current state"})),
            )
                .into_response()
        }
    };
    if !matches!(
        task.status.as_str(),
        "downloading" | "recording" | "stopping" | "merging"
    ) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Task cannot be clipped in its current state"})),
        )
            .into_response();
    }
    let stem = task
        .output_name
        .as_deref()
        .unwrap_or(&task_id[..8.min(task_id.len())])
        .trim_end_matches(".mp4")
        .to_string();
    let clip_name = format!("{stem}_clip_{suffix}.mp4");
    let clip_path = downloads_dir.join(&clip_name);
    let is_cmaf = task.is_cmaf.unwrap_or(false);
    let seg_ext = task
        .seg_ext
        .as_deref()
        .unwrap_or(".ts")
        .trim_start_matches('.')
        .to_string();

    let ffmpeg_out = if is_cmaf {
        let mut seg_files: Vec<_> = std::fs::read_dir(&tmpdir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some(&seg_ext))
            .collect();
        seg_files.sort();
        if seg_files.is_empty() {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"No segments available yet"})),
            )
                .into_response();
        }
        let raw_path = tmpdir.join("clip_raw.mp4");
        let init_file = tmpdir.join("init.mp4");
        if let Ok(mut f) = std::fs::File::create(&raw_path) {
            use std::io::Write;
            if init_file.exists() {
                let _ = f.write_all(&std::fs::read(&init_file).unwrap_or_default());
            }
            for sf in &seg_files {
                let _ = f.write_all(&std::fs::read(sf).unwrap_or_default());
            }
        }
        tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-ss",
                &body.start.to_string(),
                "-i",
                &raw_path.to_string_lossy(),
                "-t",
                &duration.to_string(),
                "-c",
                "copy",
                "-movflags",
                "+faststart",
                &clip_path.to_string_lossy(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .output()
            .await
    } else {
        let mut seg_files: Vec<_> = std::fs::read_dir(&tmpdir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("ts"))
            .collect();
        seg_files.sort();
        if seg_files.is_empty() {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"No segments available yet"})),
            )
                .into_response();
        }
        let list_file = tmpdir.join("clip_concat.txt");
        let list_content: String = seg_files
            .iter()
            .map(|p| {
                let abs = std::fs::canonicalize(p).unwrap_or_else(|_| p.clone());
                format!("file '{}'\n", abs.display())
            })
            .collect();
        let _ = tokio::fs::write(&list_file, list_content).await;
        tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                &list_file.to_string_lossy(),
                "-ss",
                &body.start.to_string(),
                "-t",
                &duration.to_string(),
                "-c",
                "copy",
                "-movflags",
                "+faststart",
                &clip_path.to_string_lossy(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .output()
            .await
    };
    match ffmpeg_out {
        Ok(o) if o.status.success() => {
            Json(serde_json::json!({"filename": clip_name})).into_response()
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr)
                .lines()
                .last()
                .unwrap_or("")
                .to_string();
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": format!("ffmpeg clip failed: {stderr}")})),
            )
                .into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"detail": format!("ffmpeg not found: {e}")})),
        )
            .into_response(),
    }
}

async fn complete_local_merge(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    Json(body): Json<LocalMergeCompleteRequest>,
) -> impl IntoResponse {
    if body.filename.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Filename is required"})),
        )
            .into_response();
    }

    let output_path = state.downloads_dir.join(&body.filename);
    if !output_path.exists() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Merged output file not found"})),
        )
            .into_response();
    }

    let mut tasks = state.tasks.write().await;
    let Some(task) = tasks.get_mut(&task_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };

    task.status = "completed".into();
    task.progress = 100;
    task.output = Some(body.filename.clone());
    task.size = body.size;
    task.duration_sec = body.duration_sec;
    task.error = None;
    drop(tasks);

    cleanup_tmpdir(&state, &task_id).await;
    state.save_tasks().await;

    Json(serde_json::json!({
        "status": "completed",
        "filename": body.filename,
    }))
    .into_response()
}

// ── WebSocket task streaming ──────────────────────────────────────────────────

async fn ws_task_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    // Auth check before upgrade
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

async fn handle_ws_task(mut socket: WebSocket, state: AppState, task_id: String) {
    // Send current snapshot immediately
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

    // If already terminal, close
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

    // Subscribe
    let (tx, mut rx) = mpsc::channel::<String>(32);
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

async fn preview_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur, is_terminal) = match preview_task_context(&task) {
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

    preview_manifest_response(build_m3u8(
        &video_segs,
        target_dur,
        is_terminal,
        &format!("/api/tasks/{task_id}/seg"),
        preview_map_uri(&task, &tmpdir, &task_id).as_deref(),
    ))
}

async fn preview_video_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur, is_terminal) = match preview_task_context(&task) {
        Ok(context) => context,
        Err(error) => return error.into_response(),
    };

    match build_preview_media_playlist(
        &tmpdir,
        &seg_ext,
        target_dur,
        is_terminal,
        &format!("/api/tasks/{task_id}/seg"),
        preview_map_uri(&task, &tmpdir, &task_id).as_deref(),
    ) {
        Ok(body) => preview_manifest_response(body),
        Err(error) => error.into_response(),
    }
}

async fn preview_audio_playlist(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
) -> impl IntoResponse {
    let tasks = state.tasks.read().await;
    let Some(task) = tasks.get(&task_id).cloned() else {
        return (StatusCode::NOT_FOUND, "Task not found".to_string()).into_response();
    };
    drop(tasks);

    let (tmpdir, seg_ext, target_dur, is_terminal) = match preview_task_context(&task) {
        Ok(context) => context,
        Err(error) => return error.into_response(),
    };
    let audio_dir = preview_audio_dir(&tmpdir);

    match build_preview_media_playlist(
        &audio_dir,
        &seg_ext,
        target_dur,
        is_terminal,
        &format!("/api/tasks/{task_id}/audio"),
        preview_audio_map_uri(&task, &tmpdir, &task_id).as_deref(),
    ) {
        Ok(body) => preview_manifest_response(body),
        Err(error) => error.into_response(),
    }
}

async fn serve_segment(
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

async fn serve_audio_segment(
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

async fn serve_download(
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
    let mut buf = vec![0u8; len as usize];
    if file.seek(SeekFrom::Start(start)).await.is_err() || file.read_exact(&mut buf).await.is_err()
    {
        return StatusCode::NOT_FOUND.into_response();
    }

    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "video/mp4")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, len.to_string())
        .header(
            header::CONTENT_DISPOSITION,
            format!("inline; filename=\"{filename}\""),
        );
    if status == StatusCode::PARTIAL_CONTENT {
        builder = builder.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }

    builder
        .body(Body::from(buf))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn parse_byte_range(range: &str, size: u64) -> Option<(u64, u64)> {
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

async fn watch_proxy(
    State(state): State<AppState>,
    Query(query): Query<WatchProxyQuery>,
) -> impl IntoResponse {
    if !query.url.starts_with("http://") && !query.url.starts_with("https://") {
        return (StatusCode::BAD_REQUEST, "Invalid watch URL").into_response();
    }

    let now = unix_now_secs();
    if let Some(entry) = state.watch_cache.read().await.get(&query.url).cloned() {
        if entry.expires_at > now {
            return Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, entry.content_type)
                .header(header::CACHE_CONTROL, entry.cache_control)
                .body(Body::from(entry.body))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
        }
    }

    let Ok(resp) = state.http_client.get(&query.url).send().await else {
        return (StatusCode::BAD_GATEWAY, "Upstream request failed").into_response();
    };

    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = resp
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
        .unwrap_or_else(|| infer_watch_content_type(&query.url));

    let Ok(bytes) = resp.bytes().await else {
        return (StatusCode::BAD_GATEWAY, "Upstream body read failed").into_response();
    };

    if !status.is_success() {
        return Response::builder()
            .status(status)
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from(bytes))
            .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response());
    }

    let (body, final_content_type, cache_control, ttl_secs) =
        if is_watch_playlist(&query.url, &content_type, &bytes) {
            let text = String::from_utf8_lossy(&bytes);
            (
                rewrite_watch_playlist(&text, &query.url).into_bytes(),
                "application/vnd.apple.mpegurl".to_string(),
                "no-store".to_string(),
                1.0,
            )
        } else {
            (
                bytes.to_vec(),
                content_type,
                "public, max-age=120".to_string(),
                120.0,
            )
        };

    state.watch_cache.write().await.insert(
        query.url.clone(),
        WatchCacheEntry {
            body: body.clone(),
            content_type: final_content_type.clone(),
            cache_control: cache_control.clone(),
            expires_at: now + ttl_secs,
        },
    );

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, final_content_type)
        .header(header::CACHE_CONTROL, cache_control)
        .body(Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn unix_now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

fn proxy_watch_url(url: &str) -> String {
    let mut qs = form_urlencoded::Serializer::new(String::new());
    qs.append_pair("url", url);
    format!("/api/watch/proxy?{}", qs.finish())
}

fn infer_watch_content_type(url: &str) -> String {
    if url.contains(".m3u8") {
        "application/vnd.apple.mpegurl".to_string()
    } else if url.contains(".ts") {
        "video/mp2t".to_string()
    } else if url.contains(".m4s") || url.contains(".mp4") {
        "video/mp4".to_string()
    } else if url.contains(".aac") {
        "audio/aac".to_string()
    } else {
        "application/octet-stream".to_string()
    }
}

fn is_watch_playlist(url: &str, content_type: &str, body: &[u8]) -> bool {
    url.contains(".m3u8")
        || content_type.contains("mpegurl")
        || content_type.contains("x-mpegurl")
        || body.starts_with(b"#EXTM3U")
}

fn rewrite_watch_playlist(text: &str, base_url: &str) -> String {
    text.lines()
        .map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return line.to_string();
            }
            if trimmed.starts_with('#') {
                return rewrite_watch_uri_attrs(line, base_url);
            }
            let resolved = resolve(trimmed, base_url);
            proxy_watch_url(&resolved)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn rewrite_watch_uri_attrs(line: &str, base_url: &str) -> String {
    let needle = "URI=\"";
    let mut out = String::new();
    let mut rest = line;

    while let Some(pos) = rest.find(needle) {
        let value_start = pos + needle.len();
        out.push_str(&rest[..value_start]);
        let value_rest = &rest[value_start..];
        let Some(value_end) = value_rest.find('"') else {
            out.push_str(value_rest);
            return out;
        };
        let raw = &value_rest[..value_end];
        let resolved = resolve(raw, base_url);
        out.push_str(&proxy_watch_url(&resolved));
        out.push('"');
        rest = &value_rest[value_end + 1..];
    }

    out.push_str(rest);
    out
}

// ── Playlist CRUD ─────────────────────────────────────────────────────────────

async fn list_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    let list: Vec<&SavedPlaylist> = pl.values().collect();
    Json(serde_json::to_value(&list).unwrap())
}

async fn add_playlist(
    State(state): State<AppState>,
    Json(body): Json<AddPlaylistRequest>,
) -> impl IntoResponse {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();

    let channels = if let Some(raw) = body.raw {
        parse_m3u_text(&raw)
    } else if let Some(ref url) = body.url {
        match fetch_m3u(url).await {
            Ok(text) => parse_m3u_text(&text),
            Err(e) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail": e})),
                )
                    .into_response()
            }
        }
    } else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail": "url or raw required"})),
        )
            .into_response();
    };

    let id = Uuid::new_v4().to_string();
    let channel_count = channels.len();
    let pl = SavedPlaylist {
        id: id.clone(),
        name: body.name,
        url: body.url,
        channels,
        created_at: now,
        updated_at: now,
        channel_count,
    };
    state.playlists.write().await.insert(id.clone(), pl.clone());
    state.save_playlists().await;
    let urls: Vec<String> = pl.channels.iter().map(|c| c.url.clone()).collect();
    trigger_health_check(state, urls).await;
    (
        StatusCode::CREATED,
        Json(serde_json::to_value(&pl).unwrap()),
    )
        .into_response()
}

async fn get_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    match pl.get(&id) {
        Some(p) => Json(serde_json::to_value(p).unwrap()).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn delete_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    state.playlists.write().await.remove(&id);
    state.save_playlists().await;
    Json(serde_json::json!({"status":"deleted"}))
}

async fn edit_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
    Json(body): Json<EditPlaylistRequest>,
) -> impl IntoResponse {
    let mut pl = state.playlists.write().await;
    let Some(entry) = pl.get_mut(&id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    if let Some(name) = body.name.filter(|s| !s.trim().is_empty()) {
        entry.name = name;
    }
    if let Some(url) = body.url {
        entry.url = if url.trim().is_empty() {
            None
        } else {
            Some(url)
        };
    }
    let result = serde_json::json!({"ok": true, "name": entry.name, "url": entry.url});
    drop(pl);
    state.save_playlists().await;
    Json(result).into_response()
}

async fn refresh_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let url = {
        let pl = state.playlists.read().await;
        let Some(entry) = pl.get(&id) else {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"Not found"})),
            )
                .into_response();
        };
        match entry.url.clone() {
            Some(u) => u,
            None => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Playlist has no URL"})),
                )
                    .into_response()
            }
        }
    };

    let text = match fetch_m3u(&url).await {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail": e})),
            )
                .into_response()
        }
    };

    let channels = parse_m3u_text(&text);
    if channels.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"No channels found"})),
        )
            .into_response();
    }

    let count = channels.len();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    {
        let mut pl = state.playlists.write().await;
        if let Some(entry) = pl.get_mut(&id) {
            entry.channels = channels;
            entry.channel_count = count;
            entry.updated_at = now;
        }
    }
    state.save_playlists().await;
    let urls: Vec<String> = {
        let pl = state.playlists.read().await;
        pl.get(&id)
            .map(|p| p.channels.iter().map(|c| c.url.clone()).collect())
            .unwrap_or_default()
    };
    trigger_health_check(state, urls).await;
    Json(serde_json::json!({"channel_count": count})).into_response()
}

async fn list_channels(State(state): State<AppState>) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    let channels: Vec<serde_json::Value> = pl
        .values()
        .flat_map(|p| {
            p.channels.iter().map(|ch| {
                serde_json::json!({
                    "name": ch.name,
                    "url": ch.url,
                    "group": ch.group,
                    "logo": ch.logo,
                    "playlist_id": p.id,
                    "playlist_name": p.name,
                })
            })
        })
        .collect();
    Json(channels)
}

async fn refresh_all_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let ids_urls: Vec<(String, String)> = {
        let pl = state.playlists.read().await;
        pl.values()
            .filter_map(|p| p.url.as_ref().map(|u| (p.id.clone(), u.clone())))
            .collect()
    };

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let mut errors: Vec<String> = Vec::new();

    for (id, url) in ids_urls {
        match fetch_m3u(&url).await {
            Ok(text) => {
                let channels = parse_m3u_text(&text);
                if !channels.is_empty() {
                    let count = channels.len();
                    let mut pl = state.playlists.write().await;
                    if let Some(entry) = pl.get_mut(&id) {
                        entry.channels = channels;
                        entry.channel_count = count;
                        entry.updated_at = now;
                    }
                }
            }
            Err(e) => errors.push(e),
        }
    }
    state.save_playlists().await;
    let urls: Vec<String> = {
        let pl = state.playlists.read().await;
        pl.values()
            .flat_map(|p| p.channels.iter().map(|c| c.url.clone()))
            .collect()
    };
    trigger_health_check(state, urls).await;
    Json(serde_json::json!({"ok": true, "errors": errors})).into_response()
}

// ── All-playlists (merged view) ───────────────────────────────────────────────

fn channel_stable_id(playlist_id: &str, url: &str) -> String {
    let mut h = Sha256::new();
    h.update(format!("{playlist_id}:{url}"));
    format!("{:x}", h.finalize())[..12].to_string()
}

fn group_stable_id(name: &str) -> String {
    let mut h = Sha256::new();
    h.update(name);
    format!("g_{:x}", h.finalize())[..14].to_string()
}

fn build_merged_view(
    playlists: &HashMap<String, SavedPlaylist>,
    existing: &MergedConfig,
) -> Vec<MergedGroup> {
    // Collect sourced channels by group name
    let mut sourced: HashMap<String, Vec<MergedChannel>> = HashMap::new();
    for pl in playlists.values() {
        for ch in &pl.channels {
            let gname = ch.group.clone().unwrap_or_else(|| "Ungrouped".into());
            let cid = channel_stable_id(&pl.id, &ch.url);
            sourced
                .entry(gname.clone())
                .or_default()
                .push(MergedChannel {
                    id: cid,
                    name: ch.name.clone(),
                    url: ch.url.clone(),
                    enabled: true,
                    custom: false,
                    group: gname,
                    tvg_logo: ch.logo.clone().unwrap_or_default(),
                    source_playlist_id: Some(pl.id.clone()),
                    source_playlist_name: Some(pl.name.clone()),
                });
        }
    }
    let known_names: HashSet<_> = existing.groups.iter().map(|g| g.name.clone()).collect();
    let mut result = Vec::new();
    for eg in &existing.groups {
        if eg.custom {
            result.push(eg.clone());
        } else if let Some(fresh) = sourced.get(&eg.name) {
            let en_map: HashMap<_, _> = eg
                .channels
                .iter()
                .map(|c| (c.id.clone(), c.enabled))
                .collect();
            let mut ng = eg.clone();
            ng.channels = fresh
                .iter()
                .map(|c| {
                    let mut nc = c.clone();
                    if let Some(&en) = en_map.get(&c.id) {
                        nc.enabled = en;
                    }
                    nc
                })
                .collect();
            result.push(ng);
        }
    }
    for (name, chs) in &sourced {
        if !known_names.contains(name) {
            result.push(MergedGroup {
                id: group_stable_id(name),
                name: name.clone(),
                enabled: true,
                custom: false,
                channels: chs.clone(),
            });
        }
    }
    result
}

async fn get_all_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let playlists = state.playlists.read().await;
    let existing = state.merged_config.read().await;
    let groups = build_merged_view(&playlists, &existing);
    drop(existing);
    drop(playlists);
    Json(serde_json::json!({"groups": groups}))
}

async fn put_all_playlists(
    State(state): State<AppState>,
    Json(body): Json<MergedConfig>,
) -> impl IntoResponse {
    *state.merged_config.write().await = body;
    state.save_merged_config().await;
    Json(serde_json::json!({"ok": true}))
}

async fn add_custom_group(
    State(state): State<AppState>,
    Json(body): Json<AddGroupRequest>,
) -> impl IntoResponse {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"name required"})),
        )
            .into_response();
    }
    {
        let mc = state.merged_config.read().await;
        if mc.groups.iter().any(|g| g.name == name) {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail":"Group already exists"})),
            )
                .into_response();
        }
    }
    let group = MergedGroup {
        id: Uuid::new_v4().to_string(),
        name: name.clone(),
        enabled: true,
        custom: true,
        channels: vec![],
    };
    state.merged_config.write().await.groups.push(group.clone());
    state.save_merged_config().await;
    (
        StatusCode::CREATED,
        Json(serde_json::json!({"ok": true, "group": group})),
    )
        .into_response()
}

async fn delete_custom_group(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    let Some(g) = mc.groups.iter().find(|g| g.id == id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    if !g.custom {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Cannot delete sourced group"})),
        )
            .into_response();
    }
    mc.groups.retain(|g| g.id != id);
    drop(mc);
    state.save_merged_config().await;
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn add_custom_channel(
    State(state): State<AppState>,
    Json(body): Json<AddChannelRequest>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    let Some(group) = mc.groups.iter_mut().find(|g| g.id == body.group_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Group not found"})),
        )
            .into_response();
    };
    let ch = MergedChannel {
        id: channel_stable_id(&body.group_id, &body.url),
        name: body.name,
        url: body.url,
        enabled: true,
        custom: true,
        group: group.name.clone(),
        tvg_logo: body.tvg_logo,
        source_playlist_id: None,
        source_playlist_name: None,
    };
    group.channels.push(ch.clone());
    drop(mc);
    state.save_merged_config().await;
    (
        StatusCode::CREATED,
        Json(serde_json::json!({"ok": true, "channel": ch})),
    )
        .into_response()
}

async fn edit_custom_channel(
    State(state): State<AppState>,
    AxumPath(ch_id): AxumPath<String>,
    Json(body): Json<EditChannelRequest>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    for group in mc.groups.iter_mut() {
        for ch in group.channels.iter_mut() {
            if ch.id == ch_id {
                if let Some(e) = body.enabled {
                    ch.enabled = e;
                }
                if let Some(ref n) = body.name {
                    if !n.trim().is_empty() {
                        ch.name = n.clone();
                    }
                }
                if let Some(ref g) = body.group {
                    ch.group = g.clone();
                }
                let result = Json(serde_json::json!({"ok": true}));
                drop(mc);
                state.save_merged_config().await;
                return result.into_response();
            }
        }
    }
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({"detail":"Channel not found"})),
    )
        .into_response()
}

async fn delete_custom_channel(
    State(state): State<AppState>,
    AxumPath(ch_id): AxumPath<String>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    for group in mc.groups.iter_mut() {
        let before = group.channels.len();
        group.channels.retain(|c| c.id != ch_id);
        if group.channels.len() < before {
            drop(mc);
            state.save_merged_config().await;
            return Json(serde_json::json!({"ok": true})).into_response();
        }
    }
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({"detail":"Not found"})),
    )
        .into_response()
}

async fn export_m3u(State(state): State<AppState>) -> impl IntoResponse {
    let playlists = state.playlists.read().await;
    let existing = state.merged_config.read().await;
    let groups = build_merged_view(&playlists, &existing);
    drop(existing);
    drop(playlists);

    let mut lines = vec!["#EXTM3U".to_string()];
    for group in groups.iter().filter(|g| g.enabled) {
        for ch in group.channels.iter().filter(|c| c.enabled) {
            let logo = if ch.tvg_logo.is_empty() {
                String::new()
            } else {
                format!(r#" tvg-logo="{}""#, ch.tvg_logo)
            };
            lines.push(format!(
                r#"#EXTINF:-1{} group-title="{}">{}"#,
                logo, group.name, ch.name
            ));
            lines.push(ch.url.clone());
        }
    }
    (
        [(header::CONTENT_TYPE, "application/x-mpegurl; charset=utf-8")],
        lines.join("\n"),
    )
        .into_response()
}

// ── Health check ──────────────────────────────────────────────────────────────

async fn get_health_check(State(state): State<AppState>) -> impl IntoResponse {
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

/// Deduplicate URLs, mark `running: true` immediately (so the next GET already
/// reflects the new state), then spawn the actual HTTP checks in the background.
/// Skips silently if a check is already running.
async fn trigger_health_check(state: AppState, urls: Vec<String>) {
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
    // Set running: true BEFORE spawning so the client sees it on the very next poll.
    *state.health_state.write().await = HealthState {
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

async fn post_health_check(State(state): State<AppState>) -> impl IntoResponse {
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
        urls.iter().filter(|u| !u.is_empty() && seen.insert(*u)).count()
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

// ── HTTP helper ───────────────────────────────────────────────────────────────

async fn fetch_m3u(url: &str) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client.get(url).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    resp.text().await.map_err(|e| e.to_string())
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn contiguous_segments(dir: &Path, ext: &str) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut idx = 0usize;
    loop {
        let p = dir.join(format!("seg_{idx:06}{ext}"));
        if !p.exists() {
            break;
        }
        if p.metadata().map(|m| m.len()).unwrap_or(0) == 0 {
            break;
        }
        result.push(p);
        idx += 1;
    }
    result
}

fn preview_task_context(task: &Task) -> Result<(PathBuf, String, u32, bool), (StatusCode, String)> {
    let Some(ref tmpdir) = task.tmpdir else {
        return Err((StatusCode::NOT_FOUND, "No preview yet".to_string()));
    };
    Ok((
        PathBuf::from(tmpdir),
        task.seg_ext.clone().unwrap_or_else(|| ".ts".into()),
        task.target_duration.unwrap_or(6.0) as u32,
        matches!(
            task.status.as_str(),
            "completed" | "failed" | "cancelled" | "merging" | "stopping" | "interrupted"
        ),
    ))
}

fn preview_audio_dir(tmpdir: &Path) -> PathBuf {
    tmpdir.join("audio")
}

fn preview_map_uri(task: &Task, tmpdir: &Path, task_id: &str) -> Option<String> {
    if task.is_cmaf != Some(true) {
        return None;
    }
    let init_path = tmpdir.join("init.mp4");
    if !init_path.exists() {
        return None;
    }
    Some(format!("/api/tasks/{task_id}/seg/init.mp4"))
}

fn preview_audio_map_uri(task: &Task, tmpdir: &Path, task_id: &str) -> Option<String> {
    if task.is_cmaf != Some(true) {
        return None;
    }
    let init_path = preview_audio_dir(tmpdir).join("init.mp4");
    if !init_path.exists() {
        return None;
    }
    Some(format!("/api/tasks/{task_id}/audio/init.mp4"))
}

fn build_preview_media_playlist(
    dir: &Path,
    seg_ext: &str,
    target_dur: u32,
    is_terminal: bool,
    base_url: &str,
    map_uri: Option<&str>,
) -> Result<String, (StatusCode, String)> {
    let segs = contiguous_segments(dir, seg_ext);
    if segs.is_empty() {
        return Err((StatusCode::NOT_FOUND, "No segments yet".to_string()));
    }
    Ok(build_m3u8(
        &segs,
        target_dur,
        is_terminal,
        base_url,
        map_uri,
    ))
}

fn build_preview_master_m3u8(task_id: &str) -> String {
    [
        "#EXTM3U".to_string(),
        "#EXT-X-VERSION:7".to_string(),
        "#EXT-X-INDEPENDENT-SEGMENTS".to_string(),
        format!(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"preview-audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"/api/tasks/{task_id}/preview-audio.m3u8\""
        ),
        format!(
            "#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"preview-audio\"\n/api/tasks/{task_id}/preview-video.m3u8"
        ),
    ]
    .join("\n")
}

fn build_m3u8(
    segs: &[PathBuf],
    target_dur: u32,
    is_terminal: bool,
    base_url: &str,
    map_uri: Option<&str>,
) -> String {
    let mut lines = vec![
        "#EXTM3U".to_string(),
        format!("#EXT-X-VERSION:{}", if map_uri.is_some() { 7 } else { 3 }),
        format!("#EXT-X-TARGETDURATION:{target_dur}"),
        "#EXT-X-MEDIA-SEQUENCE:0".to_string(),
    ];
    if !is_terminal {
        lines.push("#EXT-X-PLAYLIST-TYPE:EVENT".to_string());
    }
    if let Some(uri) = map_uri {
        lines.push(format!("#EXT-X-MAP:URI=\"{uri}\""));
    }
    for seg in segs {
        lines.push(format!("#EXTINF:{target_dur}.000,"));
        lines.push(format!(
            "{base_url}/{}",
            seg.file_name().unwrap().to_string_lossy()
        ));
    }
    if is_terminal {
        lines.push("#EXT-X-ENDLIST".to_string());
    }
    lines.join("\n")
}

fn preview_manifest_response(body: String) -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/vnd.apple.mpegurl"),
            (header::CACHE_CONTROL, "no-cache, no-store, must-revalidate"),
        ],
        body,
    )
        .into_response()
}

fn preview_segment_content_type(filename: &str, is_audio: bool) -> &'static str {
    if filename.ends_with(".ts") {
        "video/mp2t"
    } else if is_audio {
        "audio/mp4"
    } else {
        "video/mp4"
    }
}

fn preview_segment_is_valid(filename: &str) -> bool {
    regex_lite::Regex::new(r"^seg_\d{6}\.(ts|m4s|mp4)$")
        .unwrap()
        .is_match(filename)
        || filename == "init.mp4"
}

async fn serve_preview_file(
    state: AppState,
    task_id: String,
    filename: String,
    subdir: Option<&str>,
    content_type: &'static str,
) -> Response {
    if !preview_segment_is_valid(&filename) {
        return StatusCode::FORBIDDEN.into_response();
    }

    let tasks = state.tasks.read().await;
    let Some(ref tmpdir) = tasks.get(&task_id).and_then(|task| task.tmpdir.clone()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut path = PathBuf::from(tmpdir);
    if let Some(subdir) = subdir {
        path = path.join(subdir);
    }
    let seg_path = path.join(&filename);
    drop(tasks);

    if !seg_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    match tokio::fs::read(&seg_path).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, content_type)],
            bytes,
        )
            .into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

fn parse_m3u_text(text: &str) -> Vec<Channel> {
    let mut channels = Vec::new();
    let mut name = None;
    let mut group = None;
    let mut logo = None;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("#EXTINF:") {
            name = extract_attr(line, "tvg-name")
                .or_else(|| line.split(',').nth(1).map(|s| s.trim().to_string()));
            group = extract_attr(line, "group-title");
            logo = extract_attr(line, "tvg-logo");
        } else if !line.is_empty() && !line.starts_with('#') {
            if let Some(n) = name.take() {
                channels.push(Channel {
                    name: n,
                    url: line.to_string(),
                    group: group.take(),
                    logo: logo.take(),
                });
            }
        }
    }
    channels
}

fn extract_attr(line: &str, attr: &str) -> Option<String> {
    let needle = format!("{attr}=\"");
    let start = line.find(&needle)? + needle.len();
    let end = line[start..].find('"')?;
    Some(line[start..start + end].to_string())
}

// ── Load persisted state ───────────────────────────────────────────────────────

fn load_tasks(dir: &Path) -> HashMap<String, Task> {
    let path = dir.join("tasks.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let Ok(mut map): Result<HashMap<String, Task>, _> = serde_json::from_str(&content) else {
        return HashMap::new();
    };
    let active = ["downloading", "recording", "queued", "merging", "stopping"];
    for task in map.values_mut() {
        if active.contains(&task.status.as_str()) {
            task.status = "interrupted".into();
        }
    }
    map
}

fn load_playlists(dir: &Path) -> HashMap<String, SavedPlaylist> {
    let path = dir.join("playlists.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

fn load_merged_config(dir: &Path) -> MergedConfig {
    let path = dir.join("merged_config.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return MergedConfig::default();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

fn load_health_cache(dir: &Path) -> HashMap<String, HealthEntry> {
    let path = dir.join("health_cache.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

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
    fn rewrite_watch_playlist_proxies_lines_and_uri_attrs() {
        let src = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"keys/key.bin\"\n#EXTINF:6.0,\nseg_000001.ts";
        let out = rewrite_watch_playlist(src, "https://example.com/live/index.m3u8");

        assert!(out.contains("/api/watch/proxy?url=https%3A%2F%2Fexample.com%2Flive%2Finit.mp4"));
        assert!(
            out.contains("/api/watch/proxy?url=https%3A%2F%2Fexample.com%2Flive%2Fkeys%2Fkey.bin")
        );
        assert!(
            out.contains("/api/watch/proxy?url=https%3A%2F%2Fexample.com%2Flive%2Fseg_000001.ts")
        );
    }

    #[test]
    fn preview_map_uri_uses_init_segment_for_cmaf_tasks() {
        let tmpdir = std::env::temp_dir().join(format!("m3u8-preview-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        std::fs::write(tmpdir.join("init.mp4"), b"init").unwrap();

        let task = Task {
            id: "task-1".into(),
            url: "https://example.com/test.m3u8".into(),
            status: "downloading".into(),
            progress: 10,
            total: 1,
            downloaded: 0,
            failed: 0,
            speed_mbps: 0.0,
            bytes_downloaded: 0,
            output: None,
            size: 0,
            error: None,
            created_at: 0.0,
            req_headers: HashMap::new(),
            output_name: None,
            quality: "best".into(),
            concurrency: 8,
            tmpdir: Some(tmpdir.to_string_lossy().to_string()),
            is_cmaf: Some(true),
            seg_ext: Some(".m4s".into()),
            target_duration: Some(6.0),
            duration_sec: None,
            recorded_segments: None,
            elapsed_sec: None,
        };

        assert_eq!(
            preview_map_uri(&task, &tmpdir, "task-1"),
            Some("/api/tasks/task-1/seg/init.mp4".into())
        );

        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn preview_audio_map_uri_uses_audio_init_segment() {
        let tmpdir =
            std::env::temp_dir().join(format!("m3u8-preview-audio-test-{}", Uuid::new_v4()));
        let audio_dir = preview_audio_dir(&tmpdir);
        std::fs::create_dir_all(&audio_dir).unwrap();
        std::fs::write(audio_dir.join("init.mp4"), b"audio-init").unwrap();

        let task = Task {
            id: "task-1".into(),
            url: "https://example.com/test.m3u8".into(),
            status: "downloading".into(),
            progress: 10,
            total: 1,
            downloaded: 0,
            failed: 0,
            speed_mbps: 0.0,
            bytes_downloaded: 0,
            output: None,
            size: 0,
            error: None,
            created_at: 0.0,
            req_headers: HashMap::new(),
            output_name: None,
            quality: "best".into(),
            concurrency: 8,
            tmpdir: Some(tmpdir.to_string_lossy().to_string()),
            is_cmaf: Some(true),
            seg_ext: Some(".m4s".into()),
            target_duration: Some(6.0),
            duration_sec: None,
            recorded_segments: None,
            elapsed_sec: None,
        };

        assert_eq!(
            preview_audio_map_uri(&task, &tmpdir, "task-1"),
            Some("/api/tasks/task-1/audio/init.mp4".into())
        );

        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn preview_master_playlist_links_video_and_audio_manifests() {
        let body = build_preview_master_m3u8("task-1");

        assert!(body.contains("/api/tasks/task-1/preview-video.m3u8"));
        assert!(body.contains("/api/tasks/task-1/preview-audio.m3u8"));
        assert!(body.contains("#EXT-X-MEDIA:TYPE=AUDIO"));
    }

    #[tokio::test]
    async fn embedded_server_serves_auth_status_on_localhost() {
        let tmpdir = std::env::temp_dir().join(format!("m3u8-server-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();

        let server = start_embedded_server(EmbeddedServerConfig::local_device(tmpdir.clone()))
            .await
            .unwrap();

        let response = reqwest::get(format!("{}/api/auth/status", server.base_url()))
            .await
            .unwrap()
            .json::<serde_json::Value>()
            .await
            .unwrap();

        assert_eq!(response["auth_required"], false);

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }
}

// ── Server bootstrap ───────────────────────────────────────────────────────────

static TRACING_INIT: Once = Once::new();

#[derive(Debug, Clone)]
pub struct EmbeddedServerConfig {
    pub host: String,
    pub port: u16,
    pub downloads_dir: PathBuf,
    pub auth_password: Option<String>,
    pub static_dir: Option<PathBuf>,
    pub log_network_ips: bool,
}

impl EmbeddedServerConfig {
    pub fn local_device(downloads_dir: PathBuf) -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            downloads_dir,
            auth_password: None,
            static_dir: None,
            log_network_ips: false,
        }
    }

    fn advertised_host(&self) -> &str {
        match self.host.as_str() {
            "0.0.0.0" | "::" => "127.0.0.1",
            _ => &self.host,
        }
    }
}

pub struct EmbeddedServer {
    base_url: String,
    shutdown_tx: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<anyhow::Result<()>>>,
}

impl EmbeddedServer {
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub async fn wait(mut self) -> anyhow::Result<()> {
        if let Some(task) = self.task.take() {
            task.await??;
        }
        Ok(())
    }

    pub async fn stop(mut self) -> anyhow::Result<()> {
        if let Some(shutdown_tx) = self.shutdown_tx.take() {
            let _ = shutdown_tx.send(());
        }
        self.wait().await
    }
}

pub fn init_tracing() {
    TRACING_INIT.call_once(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::from_default_env()
                    .add_directive("server=info".parse().unwrap()),
            )
            .try_init();
    });
}

fn default_http_client() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")
        .build()?)
}

fn build_state(
    downloads_dir: PathBuf,
    auth_password: Option<String>,
    http_client: reqwest::Client,
) -> AppState {
    AppState {
        tasks: Arc::new(RwLock::new(load_tasks(&downloads_dir))),
        downloaders: Arc::new(RwLock::new(HashMap::new())),
        downloads_dir: downloads_dir.clone(),
        http_client,
        auth_password,
        sessions: Arc::new(RwLock::new(HashSet::new())),
        playlists: Arc::new(RwLock::new(load_playlists(&downloads_dir))),
        merged_config: Arc::new(RwLock::new(load_merged_config(&downloads_dir))),
        health_cache: Arc::new(RwLock::new(load_health_cache(&downloads_dir))),
        health_state: Arc::new(RwLock::new(HealthState::default())),
        watch_cache: Arc::new(RwLock::new(HashMap::new())),
        ws_subs: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
    }
}

fn build_api_router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/status", get(auth_status))
        .route("/api/login", post(api_login))
        .route("/api/logout", post(api_logout))
        .route("/api/parse", post(parse_stream))
        .route("/api/download", post(start_download))
        .route("/api/tasks", get(list_tasks))
        .route("/api/tasks/:id", get(get_task).delete(cancel_task))
        .route("/api/tasks/:id/clip", post(clip_task))
        .route("/api/tasks/:id/local-complete", post(complete_local_merge))
        .route("/api/tasks/:id/resume", post(resume_task))
        .route("/api/tasks/:id/recording-restart", post(recording_restart))
        .route("/api/tasks/:id/fork", post(fork_recording))
        .route("/api/tasks/:id/restart", post(restart_task))
        .route("/api/tasks/:id/preview.m3u8", get(preview_playlist))
        .route(
            "/api/tasks/:id/preview-video.m3u8",
            get(preview_video_playlist),
        )
        .route(
            "/api/tasks/:id/preview-audio.m3u8",
            get(preview_audio_playlist),
        )
        .route("/api/tasks/:id/seg/:filename", get(serve_segment))
        .route("/api/tasks/:id/audio/:filename", get(serve_audio_segment))
        .route("/api/watch/proxy", get(watch_proxy))
        .route("/downloads/:filename", get(serve_download))
        .route("/api/playlists", get(list_playlists).post(add_playlist))
        .route(
            "/api/playlists/:id",
            get(get_playlist)
                .delete(delete_playlist)
                .patch(edit_playlist),
        )
        .route("/api/playlists/:id/refresh", post(refresh_playlist))
        .route("/api/channels", get(list_channels))
        .route("/api/all-playlists/refresh", post(refresh_all_playlists))
        .route(
            "/api/all-playlists",
            get(get_all_playlists).put(put_all_playlists),
        )
        .route("/api/all-playlists/groups", post(add_custom_group))
        .route("/api/all-playlists/groups/:id", delete(delete_custom_group))
        .route("/api/all-playlists/channels", post(add_custom_channel))
        .route(
            "/api/all-playlists/channels/:id",
            patch(edit_custom_channel).delete(delete_custom_channel),
        )
        .route("/api/all-playlists/export.m3u", get(export_m3u))
        .route(
            "/api/health-check",
            get(get_health_check).post(post_health_check),
        )
        .route("/ws/tasks/:id", get(ws_task_handler))
        .route("/login", get(login_page))
}

fn build_app(state: AppState, static_dir: Option<PathBuf>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = build_api_router()
        .layer(cors)
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth_middleware,
        ))
        .with_state(state);

    match static_dir.filter(|dir| dir.is_dir()) {
        Some(dir) => app.fallback_service(ServeDir::new(dir)),
        None => app,
    }
}

fn log_network_ips(port: u16) {
    if let Ok(output) = std::process::Command::new("ifconfig").output() {
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with("inet ") && !line.contains("127.0.0.1") {
                let ip = line.split_whitespace().nth(1).unwrap_or("");
                if !ip.is_empty() {
                    info!("  → Mobile access: http://{}:{}", ip, port);
                }
            }
        }
    }
}

pub async fn start_embedded_server(config: EmbeddedServerConfig) -> anyhow::Result<EmbeddedServer> {
    init_tracing();
    std::fs::create_dir_all(&config.downloads_dir)?;

    let state = build_state(
        config.downloads_dir.clone(),
        config
            .auth_password
            .clone()
            .filter(|value| !value.is_empty()),
        default_http_client()?,
    );
    let app = build_app(state, config.static_dir.clone());

    let listener =
        tokio::net::TcpListener::bind(format!("{}:{}", config.host, config.port)).await?;
    let local_addr = listener.local_addr()?;
    let base_url = format!("http://{}:{}", config.advertised_host(), local_addr.port());
    info!("Server listening on {}", base_url);

    if config.log_network_ips {
        log_network_ips(local_addr.port());
    }

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async move {
                let _ = shutdown_rx.await;
            })
            .await
            .map_err(anyhow::Error::from)
    });

    Ok(EmbeddedServer {
        base_url,
        shutdown_tx: Some(shutdown_tx),
        task: Some(task),
    })
}

pub async fn run_from_env() -> anyhow::Result<()> {
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8765);
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let downloads_dir =
        PathBuf::from(std::env::var("DOWNLOADS_DIR").unwrap_or_else(|_| "downloads".into()));
    let static_dir = PathBuf::from(std::env::var("STATIC_DIR").unwrap_or_else(|_| "static".into()));

    let server = start_embedded_server(EmbeddedServerConfig {
        host,
        port,
        downloads_dir,
        auth_password: std::env::var("AUTH_PASSWORD")
            .ok()
            .filter(|value| !value.is_empty()),
        static_dir: Some(static_dir),
        log_network_ips: true,
    })
    .await?;

    server.wait().await
}
