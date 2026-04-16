use std::collections::HashMap;
use std::path::Path;

use crate::types::{AppSettings, HealthEntry, MergedConfig, RecentChannel, SavedPlaylist, Task};

// ── Load persisted state ───────────────────────────────────────────────────────

pub(crate) fn load_tasks(dir: &Path) -> HashMap<String, Task> {
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

pub(crate) fn load_playlists(dir: &Path) -> HashMap<String, SavedPlaylist> {
    let path = dir.join("playlists.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

pub(crate) fn load_recents(dir: &Path) -> Vec<RecentChannel> {
    let path = dir.join("recents.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

pub(crate) fn load_merged_config(dir: &Path) -> MergedConfig {
    let path = dir.join("merged_config.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return MergedConfig::default();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

pub(crate) fn load_health_cache(dir: &Path) -> HashMap<String, HealthEntry> {
    let path = dir.join("health_cache.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str(&content).unwrap_or_default()
}

pub(crate) fn load_app_settings(dir: &Path) -> AppSettings {
    let path = dir.join("settings.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return AppSettings::default();
    };
    serde_json::from_str(&content).unwrap_or_default()
}
