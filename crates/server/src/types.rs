use std::collections::HashMap;

use serde::{Deserialize, Serialize};

// ── Data types ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Task {
    pub(crate) id: String,
    pub(crate) url: String,
    pub(crate) status: String,
    pub(crate) progress: u8,
    pub(crate) total: usize,
    pub(crate) downloaded: usize,
    pub(crate) failed: usize,
    pub(crate) speed_mbps: f64,
    pub(crate) bytes_downloaded: u64,
    pub(crate) output: Option<String>,
    pub(crate) size: u64,
    pub(crate) error: Option<String>,
    pub(crate) created_at: f64,
    pub(crate) req_headers: HashMap<String, String>,
    pub(crate) output_name: Option<String>,
    pub(crate) quality: String,
    pub(crate) concurrency: usize,
    pub(crate) tmpdir: Option<String>,
    pub(crate) is_cmaf: Option<bool>,
    pub(crate) seg_ext: Option<String>,
    pub(crate) target_duration: Option<f64>,
    pub(crate) duration_sec: Option<f64>,
    pub(crate) recorded_segments: Option<usize>,
    pub(crate) elapsed_sec: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SavedPlaylist {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) url: Option<String>,
    pub(crate) channels: Vec<Channel>,
    pub(crate) created_at: f64,
    #[serde(default)]
    pub(crate) updated_at: f64,
    #[serde(default)]
    pub(crate) channel_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Channel {
    pub(crate) name: String,
    pub(crate) url: String,
    pub(crate) group: Option<String>,
    pub(crate) logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) tvg_type: Option<String>,
}

pub(crate) fn bool_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct MergedConfig {
    pub(crate) groups: Vec<MergedGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct MergedGroup {
    pub(crate) id: String,
    pub(crate) name: String,
    #[serde(default = "bool_true")]
    pub(crate) enabled: bool,
    #[serde(default)]
    pub(crate) custom: bool,
    pub(crate) channels: Vec<MergedChannel>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct OriginLabel {
    pub(crate) group_name: String,
    pub(crate) channel_name: String,
    pub(crate) source_playlist_name: String,
    pub(crate) alive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct MergedChannel {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) url: String,
    #[serde(default = "bool_true")]
    pub(crate) enabled: bool,
    #[serde(default)]
    pub(crate) custom: bool,
    #[serde(default)]
    pub(crate) group: String,
    #[serde(default)]
    pub(crate) tvg_logo: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) tvg_type: Option<String>,
    #[serde(default)]
    pub(crate) source_playlist_id: Option<String>,
    #[serde(default)]
    pub(crate) source_playlist_name: Option<String>,
    /// For custom copies created from a sourced channel: the stable ID of the origin channel.
    /// When set, name/url/tvg_logo are synced from the live source on every rebuild.
    #[serde(default)]
    pub(crate) origin_id: Option<String>,
    /// Computed at runtime by build_merged_view — describes the sync origin for the UI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) origin_label: Option<OriginLabel>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct HealthEntry {
    pub(crate) status: String,
    pub(crate) checked_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) latency_ms: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct HealthState {
    pub(crate) running: bool,
    pub(crate) total: usize,
    pub(crate) done: usize,
    pub(crate) started_at: f64,
}

#[derive(Debug, Clone)]
pub(crate) struct WatchCacheEntry {
    pub(crate) body: Vec<u8>,
    pub(crate) content_type: String,
    pub(crate) cache_control: String,
    pub(crate) expires_at: f64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct WatchProxyQuery {
    pub(crate) url: String,
    /// Caller may pass `kind=flv` (learned from `/api/watch/probe`) to skip
    /// the initial content-type detection request.
    pub(crate) kind: Option<String>,
}

// ── Request/Response models ───────────────────────────────────────────────────

#[derive(Deserialize)]
pub(crate) struct ParseRequest {
    pub(crate) url: String,
    #[serde(default)]
    pub(crate) headers: HashMap<String, String>,
}

#[derive(Deserialize)]
pub(crate) struct DownloadRequest {
    pub(crate) url: String,
    #[serde(default)]
    pub(crate) headers: HashMap<String, String>,
    #[serde(default)]
    pub(crate) output_name: Option<String>,
    #[serde(default = "default_quality")]
    pub(crate) quality: String,
    #[serde(default = "default_concurrency")]
    pub(crate) concurrency: usize,
}

pub(crate) fn default_quality() -> String {
    "best".into()
}

pub(crate) fn default_concurrency() -> usize {
    8
}

#[derive(Deserialize)]
pub(crate) struct LoginRequest {
    pub(crate) password: String,
}

#[derive(Deserialize)]
pub(crate) struct AddPlaylistRequest {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) url: Option<String>,
    #[serde(default)]
    pub(crate) raw: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct EditPlaylistRequest {
    #[serde(default)]
    pub(crate) name: Option<String>,
    #[serde(default)]
    pub(crate) url: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct AddGroupRequest {
    pub(crate) name: String,
}

#[derive(Deserialize)]
pub(crate) struct AddChannelRequest {
    pub(crate) group_id: String,
    pub(crate) name: String,
    pub(crate) url: String,
    #[serde(default)]
    pub(crate) tvg_logo: String,
}

#[derive(Deserialize)]
pub(crate) struct EditChannelRequest {
    #[serde(default)]
    pub(crate) enabled: Option<bool>,
    #[serde(default)]
    pub(crate) name: Option<String>,
    #[serde(default)]
    pub(crate) group: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct ClipRequest {
    pub(crate) start: f64,
    pub(crate) end: f64,
}

#[derive(Deserialize)]
pub(crate) struct LocalMergeCompleteRequest {
    pub(crate) filename: String,
    pub(crate) size: u64,
    #[serde(default)]
    pub(crate) duration_sec: Option<f64>,
}

#[derive(Deserialize)]
pub(crate) struct StartTranscodeBody {
    pub(crate) url: String,
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_serde_roundtrip() {
        let task = Task {
            id: "abc".into(),
            url: "https://example.com/test.m3u8".into(),
            status: "completed".into(),
            progress: 100,
            total: 10,
            downloaded: 10,
            failed: 0,
            speed_mbps: 1.5,
            bytes_downloaded: 1024,
            output: Some("out.mp4".into()),
            size: 1024,
            error: None,
            created_at: 1_700_000_000.0,
            req_headers: HashMap::new(),
            output_name: None,
            quality: "best".into(),
            concurrency: 8,
            tmpdir: None,
            is_cmaf: None,
            seg_ext: None,
            target_duration: None,
            duration_sec: Some(120.0),
            recorded_segments: None,
            elapsed_sec: None,
        };
        let json = serde_json::to_string(&task).unwrap();
        let back: Task = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, task.id);
        assert_eq!(back.status, task.status);
        assert_eq!(back.output, task.output);
    }

    #[test]
    fn merged_config_serde_roundtrip() {
        let config = MergedConfig {
            groups: vec![MergedGroup {
                id: "g1".into(),
                name: "Sports".into(),
                enabled: true,
                custom: false,
                channels: vec![MergedChannel {
                    id: "c1".into(),
                    name: "ESPN".into(),
                    url: "https://example.com/espn.m3u8".into(),
                    enabled: true,
                    custom: false,
                    group: "Sports".into(),
                    tvg_logo: String::new(),
                    tvg_type: None,
                    source_playlist_id: None,
                    source_playlist_name: None,
                    origin_id: None,
                    origin_label: None,
                }],
            }],
        };
        let json = serde_json::to_string(&config).unwrap();
        let back: MergedConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.groups.len(), 1);
        assert_eq!(back.groups[0].name, "Sports");
        assert_eq!(back.groups[0].channels[0].name, "ESPN");
    }

    #[test]
    fn merged_config_default_is_empty() {
        let mc = MergedConfig::default();
        assert!(mc.groups.is_empty());
    }
}
