use std::collections::HashSet;
use std::path::{Path, PathBuf};

use axum::{
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};

use crate::state::AppState;
use crate::types::{Channel, Task};

// ── Segment helpers ───────────────────────────────────────────────────────────

pub(crate) fn contiguous_segments(dir: &Path, ext: &str) -> Vec<PathBuf> {
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

pub(crate) fn preview_task_context(
    task: &Task,
) -> Result<(PathBuf, String, u32), (StatusCode, String)> {
    let Some(ref tmpdir) = task.tmpdir else {
        return Err((StatusCode::NOT_FOUND, "No preview yet".to_string()));
    };
    Ok((
        PathBuf::from(tmpdir),
        task.seg_ext.clone().unwrap_or_else(|| ".ts".into()),
        task.target_duration.unwrap_or(6.0) as u32,
    ))
}

pub(crate) fn preview_audio_dir(tmpdir: &Path) -> PathBuf {
    tmpdir.join("audio")
}

pub(crate) fn preview_map_uri(task: &Task, tmpdir: &Path, task_id: &str) -> Option<String> {
    if task.is_cmaf != Some(true) {
        return None;
    }
    let init_path = tmpdir.join("init.mp4");
    if !init_path.exists() {
        return None;
    }
    Some(format!("/api/tasks/{task_id}/seg/init.mp4"))
}

pub(crate) fn preview_audio_map_uri(
    task: &Task,
    tmpdir: &Path,
    task_id: &str,
) -> Option<String> {
    if task.is_cmaf != Some(true) {
        return None;
    }
    let init_path = preview_audio_dir(tmpdir).join("init.mp4");
    if !init_path.exists() {
        return None;
    }
    Some(format!("/api/tasks/{task_id}/audio/init.mp4"))
}

pub(crate) async fn build_preview_media_playlist(
    dir: PathBuf,
    seg_ext: String,
    target_dur: u32,
    base_url: String,
    map_uri: Option<String>,
) -> Result<String, (StatusCode, String)> {
    let segs = contiguous_segments(&dir, &seg_ext);
    if segs.is_empty() {
        return Err((StatusCode::NOT_FOUND, "No segments yet".to_string()));
    }
    let sections = scan_sections_async(dir.clone(), seg_ext).await;
    save_preview_sections(&dir, &sections).await;
    let first_idx = sections.first().map(|s| s.start_idx).unwrap_or(0);
    Ok(build_m3u8(
        &segs[first_idx..],
        target_dur,
        &base_url,
        map_uri.as_deref(),
        &sections,
    ))
}

pub(crate) fn build_preview_master_m3u8(task_id: &str) -> String {
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

// Segments below this size (bytes) are considered corrupt or degenerate.
pub(crate) const PREVIEW_MIN_SEGMENT_BYTES: u64 = 8_000;

pub(crate) const PREVIEW_SECTIONS_FILE: &str = "preview_sections.json";

// ── Preview discontinuity detection ──────────────────────────────────────────

/// One continuous recording session within a task's tmpdir.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub(crate) struct SectionInfo {
    /// Absolute segment index (0-based) where this section starts.
    pub(crate) start_idx: usize,
    /// Raw `baseMediaDecodeTime` of the first valid segment in this section.
    pub(crate) base_pts: u64,
}

/// Extract the zero-based segment index from a filename like `seg_000343.m4s`.
pub(crate) fn parse_seg_idx(filename: &str) -> Option<usize> {
    filename
        .strip_prefix("seg_")
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse().ok())
}

/// Scan all segments in `dir` and return a list of discontinuity sections.
pub(crate) async fn scan_sections_async(dir: PathBuf, ext: String) -> Vec<SectionInfo> {
    tokio::task::spawn_blocking(move || {
        let segs = contiguous_segments(&dir, &ext);
        if segs.is_empty() {
            return vec![];
        }

        let valid: Vec<(usize, u64)> = segs
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                p.metadata().map(|m| m.len()).unwrap_or(0) >= PREVIEW_MIN_SEGMENT_BYTES
            })
            .filter_map(|(i, p)| {
                use std::io::Read;
                let mut f = std::fs::File::open(p).ok()?;
                let mut buf = vec![0u8; 4096];
                let n = f.read(&mut buf).ok()?;
                buf.truncate(n);
                find_tfdt_in_mp4(&buf, 0, buf.len()).map(|(_, pts, _)| (i, pts))
            })
            .collect();

        if valid.is_empty() {
            return vec![];
        }

        let expected_inc: u64 = if valid.len() >= 2 {
            let inc = valid[1].1.saturating_sub(valid[0].1);
            if inc == 0 { u64::MAX } else { inc }
        } else {
            u64::MAX
        };

        let mut sections = vec![SectionInfo {
            start_idx: valid[0].0,
            base_pts: valid[0].1,
        }];

        if expected_inc == u64::MAX {
            return sections;
        }

        const DISC_JUMP_FACTOR: u64 = 4;
        for window in valid.windows(2) {
            let (_, prev_pts) = window[0];
            let (idx, pts) = window[1];
            if pts.saturating_sub(prev_pts) > expected_inc * DISC_JUMP_FACTOR {
                sections.push(SectionInfo { start_idx: idx, base_pts: pts });
            }
        }

        sections
    })
    .await
    .unwrap_or_default()
}

/// Return the `base_pts` for the section that contains `seg_idx`.
pub(crate) fn section_base_pts(sections: &[SectionInfo], seg_idx: usize) -> u64 {
    sections
        .iter()
        .rev()
        .find(|s| s.start_idx <= seg_idx)
        .map(|s| s.base_pts)
        .unwrap_or(0)
}

/// Load persisted section info from `{dir}/preview_sections.json`.
pub(crate) async fn load_preview_sections(dir: &Path) -> Vec<SectionInfo> {
    let Ok(bytes) = tokio::fs::read(dir.join(PREVIEW_SECTIONS_FILE)).await else {
        return vec![];
    };
    serde_json::from_slice(&bytes).unwrap_or_default()
}

/// Persist section info to `{dir}/preview_sections.json`.
pub(crate) async fn save_preview_sections(dir: &Path, sections: &[SectionInfo]) {
    if let Ok(json) = serde_json::to_vec(sections) {
        let _ = tokio::fs::write(dir.join(PREVIEW_SECTIONS_FILE), json).await;
    }
}

pub(crate) fn build_m3u8(
    segs: &[PathBuf],
    target_dur: u32,
    base_url: &str,
    map_uri: Option<&str>,
    sections: &[SectionInfo],
) -> String {
    let first_abs_idx = sections.first().map(|s| s.start_idx).unwrap_or(0);
    let disc_at: HashSet<usize> = sections.iter().skip(1).map(|s| s.start_idx).collect();

    let has_gaps = segs
        .iter()
        .any(|p| p.metadata().map(|m| m.len()).unwrap_or(u64::MAX) < PREVIEW_MIN_SEGMENT_BYTES);
    let version = if has_gaps { 8 } else if map_uri.is_some() { 7 } else { 3 };
    let mut lines = vec![
        "#EXTM3U".to_string(),
        format!("#EXT-X-VERSION:{version}"),
        "#EXT-X-PLAYLIST-TYPE:VOD".to_string(),
        format!("#EXT-X-TARGETDURATION:{target_dur}"),
        "#EXT-X-MEDIA-SEQUENCE:0".to_string(),
    ];
    if let Some(uri) = map_uri {
        lines.push(format!("#EXT-X-MAP:URI=\"{uri}\""));
    }
    for (pos, seg) in segs.iter().enumerate() {
        let abs_idx = first_abs_idx + pos;
        if disc_at.contains(&abs_idx) {
            lines.push("#EXT-X-DISCONTINUITY".to_string());
        }
        let size = seg.metadata().map(|m| m.len()).unwrap_or(0);
        if size < PREVIEW_MIN_SEGMENT_BYTES {
            lines.push("#EXT-X-GAP".to_string());
        }
        lines.push(format!("#EXTINF:{target_dur}.000,"));
        lines.push(format!(
            "{base_url}/{}",
            seg.file_name().unwrap().to_string_lossy()
        ));
    }
    lines.push("#EXT-X-ENDLIST".to_string());
    lines.join("\n")
}

pub(crate) fn preview_manifest_response(body: String) -> Response {
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

pub(crate) fn preview_segment_content_type(filename: &str, is_audio: bool) -> &'static str {
    if filename.ends_with(".ts") {
        "video/mp2t"
    } else if is_audio {
        "audio/mp4"
    } else {
        "video/mp4"
    }
}

pub(crate) fn preview_segment_is_valid(filename: &str) -> bool {
    regex_lite::Regex::new(r"^seg_\d{6}\.(ts|m4s|mp4)$")
        .unwrap()
        .is_match(filename)
        || filename == "init.mp4"
}

// ── fMP4 preview timestamp normalization ─────────────────────────────────────

/// Recursively walk the MP4 box tree looking for a `tfdt` box.
/// Returns `(byte_offset_of_time_field, baseMediaDecodeTime, version)`.
pub(crate) fn find_tfdt_in_mp4(
    data: &[u8],
    start: usize,
    end: usize,
) -> Option<(usize, u64, u8)> {
    let mut off = start;
    while off + 8 <= end {
        let size = u32::from_be_bytes(data[off..off + 4].try_into().ok()?) as usize;
        if size < 8 {
            break;
        }
        let box_type = &data[off + 4..off + 8];
        let box_end = (off + size).min(end);

        if box_type == b"tfdt" {
            let version = *data.get(off + 8)?;
            let time_off = off + 12;
            return if version == 1 {
                let ts = u64::from_be_bytes(data.get(time_off..time_off + 8)?.try_into().ok()?);
                Some((time_off, ts, 1))
            } else {
                let ts =
                    u32::from_be_bytes(data.get(time_off..time_off + 4)?.try_into().ok()?) as u64;
                Some((time_off, ts, 0))
            };
        }
        if matches!(box_type, b"moof" | b"traf") {
            if let Some(found) = find_tfdt_in_mp4(data, off + 8, box_end) {
                return Some(found);
            }
        }
        off += size;
    }
    None
}

/// Subtract `base_pts` from the `tfdt.baseMediaDecodeTime` in-place.
pub(crate) fn patch_tfdt(data: &mut [u8], base_pts: u64) {
    if let Some((time_off, pts, version)) = find_tfdt_in_mp4(data, 0, data.len()) {
        let new_pts = pts.saturating_sub(base_pts);
        if version == 1 {
            data[time_off..time_off + 8].copy_from_slice(&new_pts.to_be_bytes());
        } else {
            data[time_off..time_off + 4].copy_from_slice(&(new_pts as u32).to_be_bytes());
        }
    }
}

pub(crate) async fn serve_preview_file(
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
    let Some(task) = tasks.get(&task_id).cloned() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(ref tmpdir) = task.tmpdir else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let seg_ext = task.seg_ext.clone().unwrap_or_else(|| ".m4s".to_string());
    let mut path = PathBuf::from(tmpdir);
    if let Some(sd) = subdir {
        path = path.join(sd);
    }
    let seg_path = path.join(&filename);
    drop(tasks);

    if !seg_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    match tokio::fs::read(&seg_path).await {
        Ok(mut bytes) => {
            if filename.ends_with(".m4s") {
                let mut sections = load_preview_sections(&path).await;
                if sections.is_empty() {
                    sections = scan_sections_async(path.clone(), seg_ext).await;
                    save_preview_sections(&path, &sections).await;
                }
                let seg_idx = parse_seg_idx(&filename).unwrap_or(0);
                let base_pts = section_base_pts(&sections, seg_idx);
                if base_pts > 0 {
                    patch_tfdt(&mut bytes, base_pts);
                }
            }
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, content_type)],
                bytes,
            )
                .into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ── M3U text parser ───────────────────────────────────────────────────────────

pub(crate) fn parse_m3u_text(text: &str) -> Vec<Channel> {
    let mut channels = Vec::new();
    let mut name = None;
    let mut group = None;
    let mut logo = None;
    let mut tvg_type = None;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("#EXTINF:") {
            name = extract_attr(line, "tvg-name")
                .or_else(|| line.split(',').nth(1).map(|s| s.trim().to_string()));
            group = extract_attr(line, "group-title");
            logo = extract_attr(line, "tvg-logo");
            tvg_type = extract_attr(line, "tvg-type");
        } else if !line.is_empty() && !line.starts_with('#') {
            if let Some(n) = name.take() {
                channels.push(Channel {
                    name: n,
                    url: line.to_string(),
                    group: group.take(),
                    logo: logo.take(),
                    tvg_type: tvg_type.take(),
                });
            }
        }
    }
    channels
}

pub(crate) fn extract_attr(line: &str, attr: &str) -> Option<String> {
    let needle = format!("{attr}=\"");
    let start = line.find(&needle)? + needle.len();
    let end = line[start..].find('"')?;
    Some(line[start..start + end].to_string())
}

// ── HTTP helper ───────────────────────────────────────────────────────────────

pub(crate) async fn fetch_m3u(url: &str) -> Result<String, String> {
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

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── extract_attr ──────────────────────────────────────────────────────────

    #[test]
    fn extract_attr_finds_quoted_value() {
        let line = r#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0",URI="5.m3u8""#;
        assert_eq!(extract_attr(line, "GROUP-ID"), Some("audio_0".to_string()));
        assert_eq!(extract_attr(line, "URI"), Some("5.m3u8".to_string()));
    }

    #[test]
    fn extract_attr_returns_none_when_attr_missing() {
        let line = r#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0""#;
        assert_eq!(extract_attr(line, "URI"), None);
    }

    #[test]
    fn extract_attr_returns_empty_string_for_empty_value() {
        let line = r#"#EXT-X-MEDIA:URI="",GROUP-ID="grp""#;
        assert_eq!(extract_attr(line, "URI"), Some("".to_string()));
    }

    // ── build_preview_master_m3u8 ─────────────────────────────────────────────

    #[test]
    fn preview_master_playlist_links_video_and_audio_manifests() {
        let body = build_preview_master_m3u8("task-1");
        assert!(body.contains("/api/tasks/task-1/preview-video.m3u8"));
        assert!(body.contains("/api/tasks/task-1/preview-audio.m3u8"));
        assert!(body.contains("#EXT-X-MEDIA:TYPE=AUDIO"));
    }

    #[test]
    fn preview_master_playlist_starts_with_extm3u() {
        let body = build_preview_master_m3u8("some-task-id");
        assert!(body.starts_with("#EXTM3U"));
    }

    #[test]
    fn preview_master_playlist_contains_stream_inf() {
        let body = build_preview_master_m3u8("task-42");
        assert!(body.contains("#EXT-X-STREAM-INF:"));
    }

    // ── preview map URI helpers ───────────────────────────────────────────────

    #[test]
    fn preview_map_uri_uses_init_segment_for_cmaf_tasks() {
        use std::collections::HashMap;
        let tmpdir =
            std::env::temp_dir().join(format!("m3u8-preview-test-{}", uuid::Uuid::new_v4()));
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
            task_type: None,
            recording_interval_minutes: None,
            recording_auto_restart: false,
            recording_output_base: None,
        };

        assert_eq!(
            preview_map_uri(&task, &tmpdir, "task-1"),
            Some("/api/tasks/task-1/seg/init.mp4".into())
        );

        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn preview_audio_map_uri_uses_audio_init_segment() {
        use std::collections::HashMap;
        let tmpdir =
            std::env::temp_dir().join(format!("m3u8-preview-audio-test-{}", uuid::Uuid::new_v4()));
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
            task_type: None,
            recording_interval_minutes: None,
            recording_auto_restart: false,
            recording_output_base: None,
        };

        assert_eq!(
            preview_audio_map_uri(&task, &tmpdir, "task-1"),
            Some("/api/tasks/task-1/audio/init.mp4".into())
        );

        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    // ── parse_m3u_text ────────────────────────────────────────────────────────

    #[test]
    fn parse_m3u_text_parses_basic_channel() {
        let text = "#EXTM3U\n#EXTINF:-1 tvg-name=\"CNN\" group-title=\"News\",CNN\nhttps://example.com/cnn.m3u8\n";
        let channels = parse_m3u_text(text);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "CNN");
        assert_eq!(channels[0].url, "https://example.com/cnn.m3u8");
        assert_eq!(channels[0].group, Some("News".into()));
    }

    #[test]
    fn parse_m3u_text_handles_multiple_channels() {
        let text = "#EXTM3U\n#EXTINF:-1,Chan1\nhttp://a.com/1.m3u8\n#EXTINF:-1,Chan2\nhttp://a.com/2.m3u8\n";
        let channels = parse_m3u_text(text);
        assert_eq!(channels.len(), 2);
        assert_eq!(channels[0].name, "Chan1");
        assert_eq!(channels[1].name, "Chan2");
    }

    #[test]
    fn parse_m3u_text_returns_empty_for_no_channels() {
        let text = "#EXTM3U\n";
        let channels = parse_m3u_text(text);
        assert!(channels.is_empty());
    }

    // ── preview_segment_is_valid ──────────────────────────────────────────────

    #[test]
    fn preview_segment_is_valid_accepts_known_patterns() {
        assert!(preview_segment_is_valid("seg_000000.ts"));
        assert!(preview_segment_is_valid("seg_000001.m4s"));
        assert!(preview_segment_is_valid("seg_999999.mp4"));
        assert!(preview_segment_is_valid("init.mp4"));
    }

    #[test]
    fn preview_segment_is_valid_rejects_traversal() {
        assert!(!preview_segment_is_valid("../secret.ts"));
        assert!(!preview_segment_is_valid("../../etc/passwd"));
        assert!(!preview_segment_is_valid("seg_00000.ts")); // only 5 digits
        assert!(!preview_segment_is_valid("random.txt"));
    }

    // ── parse_seg_idx ─────────────────────────────────────────────────────────

    #[test]
    fn parse_seg_idx_extracts_index_from_filename() {
        assert_eq!(parse_seg_idx("seg_000000.ts"), Some(0));
        assert_eq!(parse_seg_idx("seg_000343.m4s"), Some(343));
        assert_eq!(parse_seg_idx("seg_999999.mp4"), Some(999999));
    }

    #[test]
    fn parse_seg_idx_returns_none_for_invalid() {
        assert_eq!(parse_seg_idx("init.mp4"), None);
        assert_eq!(parse_seg_idx("seg_.ts"), None);
    }
}
