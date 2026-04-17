use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    middleware,
    routing::{delete, get, patch, post},
    Router,
};
use tower_http::{
    cors::{Any, CorsLayer},
    services::ServeDir,
};
use tracing::info;

use crate::auth::auth_middleware;
use crate::handlers::{
    clip::{clip_task, complete_local_merge},
    health::{get_health_check, mark_invalid_health, post_health_check},
    merged::{
        add_custom_channel, add_custom_group, delete_custom_channel, delete_custom_group,
        edit_custom_channel, export_m3u, get_all_playlists, put_all_playlists,
    },
    playlists::{
        add_playlist, delete_playlist, edit_playlist, get_playlist, list_channels, list_playlists,
        refresh_all_playlists, refresh_playlist,
    },
    recents::{add_recent, delete_recent, list_recents},
    settings::{get_settings, patch_settings},
    tasks::{
        cancel_task, fork_recording, get_task, list_tasks, parse_stream, pause_task,
        recording_restart, restart_task, resume_task, start_download,
    },
    transcode::{start_transcode, stop_transcode, transcode_playlist, transcode_segment},
    watch::{watch_probe, watch_proxy},
    ws::{
        preview_audio_playlist, preview_playlist, preview_video_playlist, serve_audio_segment,
        serve_download, serve_segment, ws_task_handler,
    },
};
use crate::auth::{api_login, api_logout, auth_status, get_export_token, login_page};
use crate::persistence::{
    load_app_settings, load_health_cache, load_merged_config, load_playlists, load_recents,
    load_tasks,
};
use crate::state::AppState;
use crate::types::{HealthState, WatchCacheEntry};

static TRACING_INIT: std::sync::Once = std::sync::Once::new();

// ── EmbeddedServerConfig ──────────────────────────────────────────────────────

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

// ── EmbeddedServer ────────────────────────────────────────────────────────────

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

// ── Tracing init ──────────────────────────────────────────────────────────────

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

// ── HTTP client builders ──────────────────────────────────────────────────────

pub(crate) fn default_http_client() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")
        .build()?)
}

/// HTTP client for streaming media segments through the watch proxy.
/// Uses only a connect timeout — no hard body-read deadline.
pub(crate) fn proxy_stream_client() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")
        .build()?)
}

/// Client for `/api/watch/probe` with a custom redirect policy that stops
/// before following redirects to `.flv` CDN URLs.
pub(crate) fn probe_client_builder() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .danger_accept_invalid_certs(true)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let url_lower = attempt.url().to_string().to_lowercase();
            if url_lower.contains(".flv") {
                attempt.stop()
            } else if attempt.previous().len() >= 8 {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .build()?)
}

// ── State builder ─────────────────────────────────────────────────────────────

pub(crate) fn build_state(
    downloads_dir: PathBuf,
    auth_password: Option<String>,
    http_client: reqwest::Client,
    proxy_client: reqwest::Client,
    probe_client: reqwest::Client,
) -> AppState {
    AppState {
        tasks: Arc::new(tokio::sync::RwLock::new(load_tasks(&downloads_dir))),
        downloaders: Arc::new(tokio::sync::RwLock::new(HashMap::new())),
        downloads_dir: downloads_dir.clone(),
        http_client,
        proxy_client,
        probe_client,
        auth_password,
        sessions: Arc::new(tokio::sync::RwLock::new(HashSet::new())),
        playlists: Arc::new(tokio::sync::RwLock::new(load_playlists(&downloads_dir))),
        recents: Arc::new(tokio::sync::RwLock::new(load_recents(&downloads_dir))),
        merged_config: Arc::new(tokio::sync::RwLock::new(load_merged_config(&downloads_dir))),
        health_cache: Arc::new(tokio::sync::RwLock::new(load_health_cache(&downloads_dir))),
        health_state: Arc::new(tokio::sync::RwLock::new(HealthState::default())),
        watch_cache: Arc::new(tokio::sync::RwLock::new(HashMap::<String, WatchCacheEntry>::new())),
        transcodes: Arc::new(tokio::sync::RwLock::new(HashMap::new())),
        app_settings: Arc::new(tokio::sync::RwLock::new(load_app_settings(&downloads_dir))),
        ws_subs: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
    }
}

// ── API router ────────────────────────────────────────────────────────────────

pub(crate) fn build_api_router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/status", get(auth_status))
        .route("/api/auth/export-token", get(get_export_token))
        .route("/api/login", post(api_login))
        .route("/api/logout", post(api_logout))
        .route("/api/parse", post(parse_stream))
        .route("/api/download", post(start_download))
        .route("/api/tasks", get(list_tasks))
        .route("/api/tasks/:id", get(get_task).delete(cancel_task))
        .route("/api/tasks/:id/clip", post(clip_task))
        .route("/api/tasks/:id/local-complete", post(complete_local_merge))
        .route("/api/tasks/:id/resume", post(resume_task))
        .route("/api/tasks/:id/pause", post(pause_task))
        .route("/api/tasks/:id/recording-restart", post(recording_restart))
        .route("/api/tasks/:id/fork", post(fork_recording))
        .route("/api/tasks/:id/restart", post(restart_task))
        .route("/api/tasks/:id/preview.m3u8", get(preview_playlist))
        .route("/api/tasks/:id/preview-video.m3u8", get(preview_video_playlist))
        .route("/api/tasks/:id/preview-audio.m3u8", get(preview_audio_playlist))
        .route("/api/tasks/:id/seg/:filename", get(serve_segment))
        .route("/api/tasks/:id/audio/:filename", get(serve_audio_segment))
        .route("/api/watch/proxy", get(watch_proxy))
        .route("/api/watch/probe", get(watch_probe))
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
        .route("/api/recents", get(list_recents).post(add_recent))
        .route("/api/recents/:id", delete(delete_recent))
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
        .route("/api/health-check/invalid", post(mark_invalid_health))
        .route("/api/watch/transcode", post(start_transcode))
        .route("/api/watch/transcode/:id/index.m3u8", get(transcode_playlist))
        .route("/api/watch/transcode/:id/:seg", get(transcode_segment))
        .route("/api/watch/transcode/:id", delete(stop_transcode))
        .route("/ws/tasks/:id", get(ws_task_handler))
        .route("/api/settings", get(get_settings).patch(patch_settings))
        .route("/login", get(login_page))
}

// ── App builder ───────────────────────────────────────────────────────────────

pub(crate) fn build_app(state: AppState, static_dir: Option<PathBuf>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Spawn transcode session cleanup — kill idle FFmpeg processes after 60 s.
    {
        let transcodes = state.transcodes.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let idle_ids: Vec<String> = {
                    let map = transcodes.read().await;
                    map.iter()
                        .filter(|(_, s)| {
                            now.saturating_sub(
                                s.last_accessed
                                    .load(std::sync::atomic::Ordering::Relaxed),
                            ) > 60
                        })
                        .map(|(k, _)| k.clone())
                        .collect()
                };
                for key in idle_ids {
                    if let Some(session) = transcodes.write().await.remove(&key) {
                        session.kill().await;
                    }
                }
            }
        });
    }

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

// ── Network IP logging ────────────────────────────────────────────────────────

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

// ── Public server entry points ────────────────────────────────────────────────

pub async fn start_embedded_server(
    config: EmbeddedServerConfig,
) -> anyhow::Result<EmbeddedServer> {
    init_tracing();
    std::fs::create_dir_all(&config.downloads_dir)?;

    let state = build_state(
        config.downloads_dir.clone(),
        config
            .auth_password
            .clone()
            .filter(|value| !value.is_empty()),
        default_http_client()?,
        proxy_stream_client()?,
        probe_client_builder()?,
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
    // Prefer the Vite build output (static/dist/) when present; fall back to static/
    let static_dir = {
        let base = PathBuf::from(std::env::var("STATIC_DIR").unwrap_or_else(|_| "static".into()));
        let dist = base.join("dist");
        if dist.is_dir() { dist } else { base }
    };

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

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::HashMap, io::Write, time::Duration};

    use serde_json::json;

    use crate::types::Task;

    async fn spawn_test_server(tmpdir: &std::path::Path) -> EmbeddedServer {
        start_embedded_server(EmbeddedServerConfig::local_device(tmpdir.to_path_buf()))
            .await
            .unwrap()
    }

    fn sample_task(task_id: &str, tmpdir: Option<String>) -> Task {
        Task {
            id: task_id.to_string(),
            url: "https://example.com/live.m3u8".into(),
            status: "recording".into(),
            progress: 0,
            total: 0,
            downloaded: 0,
            failed: 0,
            speed_mbps: 0.0,
            bytes_downloaded: 0,
            output: None,
            size: 0,
            error: None,
            created_at: 1.0,
            req_headers: HashMap::new(),
            output_name: Some("Demo Channel".into()),
            quality: "best".into(),
            concurrency: 8,
            tmpdir,
            is_cmaf: Some(true),
            seg_ext: Some("m4s".into()),
            target_duration: Some(6.0),
            duration_sec: None,
            recorded_segments: Some(1),
            elapsed_sec: Some(61),
            task_type: None,
            recording_interval_minutes: Some(60),
            recording_auto_restart: true,
            recording_output_base: Some("Demo Channel".into()),
        }
    }

    fn looks_like_timestamped_name(value: &str, base: &str) -> bool {
        let Some(suffix) = value.strip_prefix(&format!("{base}_")) else {
            return false;
        };
        let parts: Vec<_> = suffix.split('-').collect();
        parts.len() == 3
            && parts
                .iter()
                .all(|part| part.len() == 2 && part.chars().all(|ch| ch.is_ascii_digit()))
    }

    #[tokio::test]
    async fn embedded_server_serves_auth_status_on_localhost() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();

        let server = spawn_test_server(&tmpdir).await;

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

    #[tokio::test]
    async fn recents_post_dedupes_and_sorts_latest_first() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let alpha = json!({
            "name": "Alpha",
            "url": "https://example.com/a.m3u8",
            "tvg_logo": "",
            "group": "News"
        });
        let beta = json!({
            "name": "Beta",
            "url": "https://example.com/b.m3u8",
            "tvg_logo": "",
            "group": "Sports"
        });

        client.post(format!("{}/api/recents", server.base_url())).json(&alpha).send().await.unwrap();
        client.post(format!("{}/api/recents", server.base_url())).json(&beta).send().await.unwrap();
        client.post(format!("{}/api/recents", server.base_url())).json(&alpha).send().await.unwrap();

        let response = client
            .get(format!("{}/api/recents", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
        let recents = response.json::<Vec<serde_json::Value>>().await.unwrap();

        assert_eq!(recents.len(), 2);
        assert_eq!(recents[0]["url"], "https://example.com/a.m3u8");
        assert_eq!(recents[1]["url"], "https://example.com/b.m3u8");

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn recents_delete_removes_one_entry() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let payload = json!({
            "name": "Gamma",
            "url": "https://example.com/gamma.m3u8",
            "tvg_logo": "",
            "group": "Movies"
        });

        let create = client
            .post(format!("{}/api/recents", server.base_url()))
            .json(&payload)
            .send()
            .await
            .unwrap();
        assert!(create.status().is_success());
        let created = create.json::<serde_json::Value>().await.unwrap();
        let id = created["id"].as_str().unwrap();

        let delete = client
            .delete(format!("{}/api/recents/{}", server.base_url(), id))
            .send()
            .await
            .unwrap();
        assert!(delete.status().is_success());

        let response = client
            .get(format!("{}/api/recents", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
        let recents = response.json::<Vec<serde_json::Value>>().await.unwrap();
        assert!(recents.is_empty());

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn app_settings_round_trip_includes_recent_limit() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let patch = client
            .patch(format!("{}/api/settings", server.base_url()))
            .json(&json!({ "recent_limit": 12 }))
            .send()
            .await
            .unwrap();
        assert!(patch.status().is_success());
        let patched = patch.json::<serde_json::Value>().await.unwrap();
        assert_eq!(patched["recent_limit"], 12);

        let get = client
            .get(format!("{}/api/settings", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(get.status().is_success());
        let current = get.json::<serde_json::Value>().await.unwrap();
        assert_eq!(current["recent_limit"], 12);

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn app_settings_round_trip_includes_auto_fullscreen() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let patch = client
            .patch(format!("{}/api/settings", server.base_url()))
            .json(&json!({ "auto_fullscreen": true }))
            .send()
            .await
            .unwrap();
        assert!(patch.status().is_success());
        let patched = patch.json::<serde_json::Value>().await.unwrap();
        assert_eq!(patched["auto_fullscreen"], true);

        let get = client
            .get(format!("{}/api/settings", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(get.status().is_success());
        let current = get.json::<serde_json::Value>().await.unwrap();
        assert_eq!(current["auto_fullscreen"], true);

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn recents_respect_recent_limit_setting() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let patch = client
            .patch(format!("{}/api/settings", server.base_url()))
            .json(&json!({ "recent_limit": 2 }))
            .send()
            .await
            .unwrap();
        assert!(patch.status().is_success());

        for (name, url) in [
            ("One", "https://example.com/one.m3u8"),
            ("Two", "https://example.com/two.m3u8"),
            ("Three", "https://example.com/three.m3u8"),
        ] {
            let response = client
                .post(format!("{}/api/recents", server.base_url()))
                .json(&json!({
                    "name": name,
                    "url": url,
                    "tvg_logo": "",
                    "group": "Test"
                }))
                .send()
                .await
                .unwrap();
            assert!(response.status().is_success());
        }

        let response = client
            .get(format!("{}/api/recents", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
        let recents = response.json::<Vec<serde_json::Value>>().await.unwrap();
        assert_eq!(recents.len(), 2);
        assert_eq!(recents[0]["url"], "https://example.com/three.m3u8");
        assert_eq!(recents[1]["url"], "https://example.com/two.m3u8");

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn live_clip_returns_before_segment_snapshot_finishes() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();

        let recording_tmpdir = tmpdir.join("recording-task");
        std::fs::create_dir_all(&recording_tmpdir).unwrap();
        let fifo_path = recording_tmpdir.join("0001.m4s");
        let status = std::process::Command::new("mkfifo")
            .arg(&fifo_path)
            .status()
            .unwrap();
        assert!(status.success());

        let task_id = uuid::Uuid::new_v4().to_string();
        let tasks = HashMap::from([(
            task_id.clone(),
            sample_task(&task_id, Some(recording_tmpdir.to_string_lossy().to_string())),
        )]);
        std::fs::write(
            tmpdir.join("tasks.json"),
            serde_json::to_vec(&tasks).unwrap(),
        )
        .unwrap();

        let fifo_writer = fifo_path.clone();
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .open(fifo_writer)
                .unwrap();
            file.write_all(b"not-a-real-fragment").unwrap();
        });

        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();
        let response = tokio::time::timeout(
            Duration::from_millis(150),
            client
                .post(format!("{}/api/tasks/{}/clip", server.base_url(), task_id))
                .json(&json!({ "start": 0.0, "end": 8.0 }))
                .send(),
        )
        .await
        .expect("clip response should not block on segment preparation")
        .unwrap();
        assert!(response.status().is_success());

        let payload = response.json::<serde_json::Value>().await.unwrap();
        assert!(payload["clip_task_id"].as_str().is_some());

        writer.join().unwrap();
        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn app_settings_round_trip_includes_recording_interval_fields() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let patch = client
            .patch(format!("{}/api/settings", server.base_url()))
            .json(&json!({
                "recording_interval_minutes": 90,
                "recording_auto_restart": true
            }))
            .send()
            .await
            .unwrap();
        assert!(patch.status().is_success());
        let patched = patch.json::<serde_json::Value>().await.unwrap();
        assert_eq!(patched["recording_interval_minutes"], 90);
        assert_eq!(patched["recording_auto_restart"], true);

        let get = client
            .get(format!("{}/api/settings", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(get.status().is_success());
        let current = get.json::<serde_json::Value>().await.unwrap();
        assert_eq!(current["recording_interval_minutes"], 90);
        assert_eq!(current["recording_auto_restart"], true);

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[tokio::test]
    async fn start_download_persists_recording_preferences_and_timestamps_name() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let response = client
            .post(format!("{}/api/download", server.base_url()))
            .json(&json!({
                "url": "https://example.com/live.m3u8",
                "headers": {},
                "output_name": "Demo Channel",
                "quality": "best",
                "concurrency": 8,
                "recording_interval_minutes": 60,
                "recording_auto_restart": true
            }))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
        let task_id = response.json::<serde_json::Value>().await.unwrap()["task_id"]
            .as_str()
            .unwrap()
            .to_string();

        let task = client
            .get(format!("{}/api/tasks/{}", server.base_url(), task_id))
            .send()
            .await
            .unwrap()
            .json::<serde_json::Value>()
            .await
            .unwrap();

        assert_eq!(task["recording_interval_minutes"], 60);
        assert_eq!(task["recording_auto_restart"], true);
        assert_eq!(task["recording_output_base"], "Demo Channel");
        let output_name = task["output_name"].as_str().unwrap_or_default();
        assert!(looks_like_timestamped_name(output_name, "Demo Channel"));

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn recording_successor_task_gets_fresh_timestamped_output_name() {
        let source = sample_task("source-task", None);
        let next = crate::handlers::tasks::make_task("next-task", &source, 1.0);
        let output_name = next.output_name.as_deref().unwrap_or_default();
        assert!(looks_like_timestamped_name(output_name, "Demo Channel"));
        assert_ne!(output_name, "Demo Channel");
    }

    #[tokio::test]
    async fn mark_invalid_updates_health_cache() {
        let tmpdir = std::env::temp_dir()
            .join(format!("m3u8-server-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let server = spawn_test_server(&tmpdir).await;
        let client = reqwest::Client::new();

        let response = client
            .post(format!("{}/api/health-check/invalid", server.base_url()))
            .json(&json!({ "url": "http://example.com/live.m3u8" }))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());

        let state = client
            .get(format!("{}/api/health-check", server.base_url()))
            .send()
            .await
            .unwrap();
        assert!(state.status().is_success());
        let payload = state.json::<serde_json::Value>().await.unwrap();
        assert_eq!(
            payload["cache"]["http://example.com/live.m3u8"]["status"],
            "invalid"
        );

        server.stop().await.unwrap();
        let _ = std::fs::remove_dir_all(&tmpdir);
    }
}
