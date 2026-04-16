use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::{mpsc, RwLock};

use crate::types::{
    AppSettings, HealthEntry, HealthState, MergedConfig, RecentChannel, SavedPlaylist, Task,
    WatchCacheEntry,
};

// ── Transcode session (FLV → HLS via FFmpeg) ─────────────────────────────────

/// One live FLV→HLS transcode session.  FFmpeg reads the FLV stream directly
/// from the CDN URL (single connection — satisfies Huya/Tengine per-IP limit)
/// and writes HLS segments to a temp directory.  Playlist requests read those
/// files and rewrite segment URLs to go back through our server.
pub(crate) struct TranscodeSession {
    /// Unique session ID (UUID4, used in segment URLs).
    pub(crate) id: String,
    /// Original (pre-redirect) URL supplied by the caller — used as map key so
    /// the same channel isn't transcoded twice.
    pub(crate) source_url: String,
    /// Temp directory where FFmpeg writes `index.m3u8` and `seg_*.ts`.
    pub(crate) tmp_dir: PathBuf,
    /// FFmpeg child process.  Held so we can kill it on cleanup.
    pub(crate) child: tokio::sync::Mutex<Option<tokio::process::Child>>,
    /// Unix timestamp (seconds) of last playlist / segment request.
    pub(crate) last_accessed: std::sync::atomic::AtomicU64,
}

impl TranscodeSession {
    pub(crate) fn touch(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.last_accessed
            .store(now, std::sync::atomic::Ordering::Relaxed);
    }

    pub(crate) async fn kill(&self) {
        let mut guard = self.child.lock().await;
        if let Some(ref mut child) = *guard {
            let _ = child.kill().await;
        }
        *guard = None;
        let _ = tokio::fs::remove_dir_all(&self.tmp_dir).await;
    }
}

// ── App State ─────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub(crate) struct AppState {
    pub(crate) tasks: Arc<RwLock<HashMap<String, Task>>>,
    pub(crate) downloaders: Arc<RwLock<HashMap<String, Arc<m3u8_core::Downloader>>>>,
    pub(crate) downloads_dir: PathBuf,
    pub(crate) http_client: reqwest::Client,
    /// Separate client for streaming media segments — no hard body timeout so
    /// large `.ts` files are streamed through without being cut off.
    pub(crate) proxy_client: reqwest::Client,
    /// Client for `/api/watch/probe`.  Uses a custom redirect policy that stops
    /// before redirecting to `.flv` CDN URLs so we can read the signed URL from
    /// the `Location` header WITHOUT opening a CDN connection.
    pub(crate) probe_client: reqwest::Client,
    pub(crate) auth_password: Option<String>,
    pub(crate) sessions: Arc<RwLock<HashSet<String>>>,
    pub(crate) playlists: Arc<RwLock<HashMap<String, SavedPlaylist>>>,
    pub(crate) recents: Arc<RwLock<Vec<RecentChannel>>>,
    pub(crate) merged_config: Arc<RwLock<MergedConfig>>,
    pub(crate) health_cache: Arc<RwLock<HashMap<String, HealthEntry>>>,
    pub(crate) health_state: Arc<RwLock<HealthState>>,
    pub(crate) watch_cache: Arc<RwLock<HashMap<String, WatchCacheEntry>>>,
    /// Active FLV→HLS transcode sessions keyed by source_url.
    pub(crate) transcodes: Arc<RwLock<HashMap<String, Arc<TranscodeSession>>>>,
    pub(crate) app_settings: Arc<RwLock<AppSettings>>,
    pub(crate) ws_subs: Arc<tokio::sync::Mutex<HashMap<String, Vec<mpsc::Sender<String>>>>>,
}

impl AppState {
    pub(crate) async fn save_tasks(&self) {
        let path = self.downloads_dir.join("tasks.json");
        let tasks = self.tasks.read().await;
        let _ = tokio::fs::write(
            &path,
            serde_json::to_vec_pretty(&*tasks).unwrap_or_default(),
        )
        .await;
    }

    pub(crate) async fn save_playlists(&self) {
        let path = self.downloads_dir.join("playlists.json");
        let pl = self.playlists.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*pl).unwrap_or_default()).await;
    }

    pub(crate) async fn save_recents(&self) {
        let path = self.downloads_dir.join("recents.json");
        let recents = self.recents.read().await;
        let _ =
            tokio::fs::write(&path, serde_json::to_vec_pretty(&*recents).unwrap_or_default()).await;
    }

    pub(crate) async fn save_merged_config(&self) {
        let path = self.downloads_dir.join("merged_config.json");
        let mc = self.merged_config.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*mc).unwrap_or_default()).await;
    }

    pub(crate) async fn save_health_cache(&self) {
        let path = self.downloads_dir.join("health_cache.json");
        let hc = self.health_cache.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*hc).unwrap_or_default()).await;
    }

    pub(crate) async fn save_app_settings(&self) {
        let path = self.downloads_dir.join("settings.json");
        let s = self.app_settings.read().await;
        let _ = tokio::fs::write(&path, serde_json::to_vec_pretty(&*s).unwrap_or_default()).await;
    }
}
