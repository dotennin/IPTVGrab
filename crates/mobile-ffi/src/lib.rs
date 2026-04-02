use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use m3u8_core::{DownloadConfig, Downloader, ProgressEvent, Quality};
use server::EmbeddedServerConfig;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

// UniFFI proc-macro scaffolding
uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum FfiError {
    #[error("{message}")]
    Message { message: String },
}

// ── Single shared Tokio runtime for mobile ────────────────────────────────────

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("Failed to create Tokio runtime"))
}

struct LocalServerRuntime {
    base_url: String,
    handle: server::EmbeddedServer,
}

static LOCAL_SERVER: OnceLock<Mutex<Option<LocalServerRuntime>>> = OnceLock::new();

fn local_server_slot() -> &'static Mutex<Option<LocalServerRuntime>> {
    LOCAL_SERVER.get_or_init(|| Mutex::new(None))
}

// ── FFI-exposed types (must be simple; no lifetimes) ─────────────────────────

#[derive(uniffi::Record, Clone)]
pub struct FfiDownloadConfig {
    pub url: String,
    pub headers: HashMap<String, String>,
    pub output_dir: String,
    pub output_name: Option<String>,
    pub quality: String, // "best" | "worst" | "<index>"
    pub concurrency: u32,
    pub task_id: Option<String>,
}

#[derive(uniffi::Enum, Clone)]
pub enum FfiProgressEvent {
    Downloading {
        total: u64,
        downloaded: u64,
        failed: u64,
        progress: u8,
        speed_mbps: f64,
        bytes_downloaded: u64,
        tmpdir: String,
        is_cmaf: bool,
        seg_ext: String,
        target_duration: f64,
    },
    Recording {
        recorded_segments: u64,
        bytes_downloaded: u64,
        speed_mbps: f64,
        elapsed_sec: u64,
        tmpdir: String,
        is_cmaf: bool,
        seg_ext: String,
        target_duration: f64,
    },
    Merging {
        progress: u8,
    },
    Completed {
        output: String,
        size: u64,
        duration_sec: f64,
    },
    Failed {
        error: String,
    },
    Cancelled,
    Paused,
}

#[derive(uniffi::Record, Clone)]
pub struct FfiStreamInfo {
    pub kind: String,
    pub streams: Vec<FfiVariant>,
    pub segments: u64,
    pub duration: f64,
    pub encrypted: bool,
    pub is_live: bool,
}

#[derive(uniffi::Record, Clone)]
pub struct FfiVariant {
    pub url: String,
    pub bandwidth: u64,
    pub resolution: Option<String>,
    pub label: String,
    pub codecs: Option<String>,
}

// ── Callback interface (Swift/Kotlin implement this) ──────────────────────────

#[uniffi::export(callback_interface)]
pub trait ProgressCallback: Send + Sync {
    fn on_event(&self, event: FfiProgressEvent);
}

// ── DownloadEngine object ─────────────────────────────────────────────────────

#[derive(uniffi::Object)]
pub struct DownloadEngine {
    inner: Arc<Downloader>,
}

#[uniffi::export]
impl DownloadEngine {
    #[uniffi::constructor]
    pub fn new(config: FfiDownloadConfig) -> Arc<Self> {
        let quality = match config.quality.as_str() {
            "worst" => Quality::Worst,
            s if s.parse::<usize>().is_ok() => Quality::Index(s.parse().unwrap()),
            _ => Quality::Best,
        };
        let core_config = DownloadConfig {
            url: config.url,
            headers: config.headers,
            output_dir: PathBuf::from(&config.output_dir),
            output_name: config.output_name,
            quality,
            concurrency: config.concurrency as usize,
            task_id: config
                .task_id
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            ..Default::default()
        };
        Arc::new(Self {
            inner: Arc::new(Downloader::new(core_config)),
        })
    }

    /// Parse stream metadata synchronously (blocks calling thread).
    pub fn parse_sync(&self) -> Result<FfiStreamInfo, FfiError> {
        runtime()
            .block_on(self.inner.parse())
            .map(|info| FfiStreamInfo {
                kind: format!("{:?}", info.kind).to_lowercase(),
                streams: info
                    .streams
                    .iter()
                    .map(|v| FfiVariant {
                        url: v.url.clone(),
                        bandwidth: v.bandwidth,
                        resolution: v.resolution.clone(),
                        label: v.label.clone(),
                        codecs: v.codecs.clone(),
                    })
                    .collect(),
                segments: info.segments as u64,
                duration: info.duration,
                encrypted: info.encrypted,
                is_live: info.is_live,
            })
            .map_err(|e| FfiError::Message {
                message: e.to_string(),
            })
    }

    /// Start downloading; calls callback.on_event() for each progress event.
    /// Returns immediately; download runs on internal Tokio runtime threads.
    pub fn start(&self, callback: Box<dyn ProgressCallback>) {
        let dl = self.inner.clone();
        let cb = Arc::new(callback);
        runtime().spawn(async move {
            let (tx, mut rx) = mpsc::channel::<ProgressEvent>(64);
            let cb_clone = cb.clone();
            tokio::spawn(async move {
                while let Some(event) = rx.recv().await {
                    cb_clone.on_event(to_ffi(event));
                }
            });
            let _ = dl.download(tx).await;
        });
    }

    /// Cancel an active download (discard segments).
    pub fn cancel(&self) {
        self.inner.cancel();
    }

    /// Stop a live recording and proceed to merge.
    pub fn stop_recording(&self) {
        self.inner.stop();
    }
}

// ── Free functions ────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn start_local_server(
    port: u16,
    downloads_dir: String,
    auth_password: Option<String>,
) -> Result<String, FfiError> {
    start_local_server_inner(port, downloads_dir, auth_password)
}

#[uniffi::export]
pub fn stop_local_server() -> Result<(), FfiError> {
    stop_local_server_inner()
}

#[uniffi::export]
pub fn local_server_base_url() -> Option<String> {
    local_server_slot()
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|server| server.base_url.clone()))
}

fn start_local_server_inner(
    port: u16,
    downloads_dir: String,
    auth_password: Option<String>,
) -> Result<String, FfiError> {
    let mut slot = local_server_slot().lock().map_err(|_| FfiError::Message {
        message: "Local server lock poisoned".into(),
    })?;

    if let Some(server) = slot.as_ref() {
        return Ok(server.base_url.clone());
    }

    let mut config = EmbeddedServerConfig::local_device(PathBuf::from(downloads_dir));
    config.port = port;
    config.auth_password = auth_password.filter(|value| !value.is_empty());

    let handle = runtime()
        .block_on(server::start_embedded_server(config))
        .map_err(|error| FfiError::Message {
            message: error.to_string(),
        })?;
    let base_url = handle.base_url().to_string();

    *slot = Some(LocalServerRuntime {
        base_url: base_url.clone(),
        handle,
    });

    Ok(base_url)
}

fn stop_local_server_inner() -> Result<(), FfiError> {
    let server_runtime = {
        let mut slot = local_server_slot().lock().map_err(|_| FfiError::Message {
            message: "Local server lock poisoned".into(),
        })?;
        slot.take()
    };

    if let Some(server) = server_runtime {
        runtime()
            .block_on(server.handle.stop())
            .map_err(|error| FfiError::Message {
                message: error.to_string(),
            })?;
    }

    Ok(())
}

#[unsafe(no_mangle)]
pub extern "C" fn m3u8_local_server_start(
    port: u16,
    downloads_dir: *const c_char,
    auth_password: *const c_char,
) -> *mut c_char {
    let response = match required_c_string(downloads_dir).and_then(|dir| {
        let password = optional_c_string(auth_password)?;
        start_local_server_inner(port, dir, password)
    }) {
        Ok(base_url) => serde_json::json!({
            "ok": true,
            "base_url": base_url,
        }),
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error.to_string(),
        }),
    };

    into_c_string(response.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn m3u8_local_server_status() -> *mut c_char {
    let payload = match local_server_slot().lock() {
        Ok(slot) => match slot.as_ref() {
            Some(server) => serde_json::json!({
                "running": true,
                "base_url": server.base_url,
            }),
            None => serde_json::json!({
                "running": false,
            }),
        },
        Err(_) => serde_json::json!({
            "running": false,
            "error": "Local server lock poisoned",
        }),
    };

    into_c_string(payload.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn m3u8_local_server_stop() -> *mut c_char {
    let payload = match stop_local_server_inner() {
        Ok(()) => serde_json::json!({ "ok": true }),
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error.to_string(),
        }),
    };

    into_c_string(payload.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn m3u8_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .expect("CString conversion should not fail for JSON")
        .into_raw()
}

fn optional_c_string(ptr: *const c_char) -> Result<Option<String>, FfiError> {
    if ptr.is_null() {
        return Ok(None);
    }
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|error| FfiError::Message {
            message: error.to_string(),
        })?
        .trim()
        .to_string();
    if value.is_empty() {
        Ok(None)
    } else {
        Ok(Some(value))
    }
}

fn required_c_string(ptr: *const c_char) -> Result<String, FfiError> {
    optional_c_string(ptr)?.ok_or_else(|| FfiError::Message {
        message: "downloads_dir is required".into(),
    })
}

// ── Conversion ────────────────────────────────────────────────────────────────

fn to_ffi(event: ProgressEvent) -> FfiProgressEvent {
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
        } => FfiProgressEvent::Downloading {
            total: total as u64,
            downloaded: downloaded as u64,
            failed: failed as u64,
            progress,
            speed_mbps,
            bytes_downloaded,
            tmpdir,
            is_cmaf,
            seg_ext,
            target_duration,
        },
        ProgressEvent::Recording {
            recorded_segments,
            bytes_downloaded,
            speed_mbps,
            elapsed_sec,
            tmpdir,
            is_cmaf,
            seg_ext,
            target_duration,
        } => FfiProgressEvent::Recording {
            recorded_segments: recorded_segments as u64,
            bytes_downloaded,
            speed_mbps,
            elapsed_sec,
            tmpdir,
            is_cmaf,
            seg_ext,
            target_duration,
        },
        ProgressEvent::Merging { progress } => FfiProgressEvent::Merging { progress },
        ProgressEvent::Completed {
            output,
            size,
            duration_sec,
        } => FfiProgressEvent::Completed {
            output,
            size,
            duration_sec,
        },
        ProgressEvent::Failed { error } => FfiProgressEvent::Failed { error },
        ProgressEvent::Cancelled => FfiProgressEvent::Cancelled,
        ProgressEvent::Paused => FfiProgressEvent::Paused,
    }
}
