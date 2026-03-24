use serde::{Deserialize, Serialize};

// ── Configuration ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct DownloadConfig {
    pub url: String,
    pub headers: std::collections::HashMap<String, String>,
    pub output_dir: std::path::PathBuf,
    pub output_name: Option<String>,
    pub quality: Quality,
    pub concurrency: usize,
    pub retry: u32,
    pub task_id: String,
}

impl Default for DownloadConfig {
    fn default() -> Self {
        Self {
            url: String::new(),
            headers: Default::default(),
            output_dir: std::path::PathBuf::from("downloads"),
            output_name: None,
            quality: Quality::Best,
            concurrency: 8,
            retry: 3,
            task_id: uuid::Uuid::new_v4().to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub enum Quality {
    Best,
    Worst,
    Index(usize),
}

// ── Stream metadata (returned by parse()) ─────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamInfo {
    pub kind: StreamKind,
    /// Only set for master playlists
    pub streams: Vec<VariantInfo>,
    /// Only set for media playlists
    pub segments: usize,
    pub duration: f64,
    pub encrypted: bool,
    pub is_live: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum StreamKind {
    Master,
    Media,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VariantInfo {
    pub url: String,
    pub bandwidth: u64,
    pub resolution: Option<String>,
    pub label: String,
    pub codecs: Option<String>,
}

// ── Progress events (yielded by download()) ───────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ProgressEvent {
    Downloading {
        total: usize,
        downloaded: usize,
        failed: usize,
        progress: u8,
        speed_mbps: f64,
        bytes_downloaded: u64,
        tmpdir: String,
        is_cmaf: bool,
        seg_ext: String,
        target_duration: f64,
    },
    Recording {
        recorded_segments: usize,
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
}
