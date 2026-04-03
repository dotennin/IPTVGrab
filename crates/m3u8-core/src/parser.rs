use std::collections::{HashMap, HashSet};

use m3u8_rs::{AlternativeMediaType, KeyMethod, MediaPlaylist, Playlist};
use url::Url;

use crate::error::DownloadError;
use crate::types::{Quality, StreamInfo, StreamKind, VariantInfo};

#[derive(Debug, Clone)]
struct ParsedMasterVariant {
    info: VariantInfo,
    audio_group: Option<String>,
}

#[derive(Debug, Clone)]
struct ParsedMasterAudioRendition {
    group_id: String,
    uri: String,
    is_default: bool,
}

#[derive(Debug, Clone, Default)]
struct ParsedMasterManifest {
    variants: Vec<ParsedMasterVariant>,
    audio_renditions: Vec<ParsedMasterAudioRendition>,
}

/// Resolve a relative URI against a base URL.
pub fn resolve(uri: &str, base: &str) -> String {
    if uri.starts_with("http://") || uri.starts_with("https://") {
        return uri.to_string();
    }
    if let Ok(base_url) = Url::parse(base) {
        if let Ok(resolved) = base_url.join(uri) {
            return resolved.to_string();
        }
    }
    uri.to_string()
}

/// Parse raw M3U8 bytes into a Playlist enum.
pub fn parse_playlist(content: &str) -> Result<Playlist, DownloadError> {
    let bytes = content.as_bytes();
    match m3u8_rs::parse_playlist_res(bytes) {
        Ok(pl) => Ok(pl),
        Err(e) => Err(DownloadError::Parse(e.to_string())),
    }
}

/// Extract StreamInfo metadata from a playlist.
pub fn playlist_to_info(playlist: &Playlist, content: &str, base_url: &str) -> StreamInfo {
    match playlist {
        Playlist::MasterPlaylist(master) => {
            let mut streams = parse_master_manifest(content, base_url)
                .map(|parsed| {
                    parsed
                        .variants
                        .into_iter()
                        .map(|variant| variant.info)
                        .collect::<Vec<_>>()
                })
                .filter(|streams| !streams.is_empty())
                .unwrap_or_else(|| {
                    master
                        .variants
                        .iter()
                        .map(|v| {
                            let resolution =
                                v.resolution.map(|r| format!("{}x{}", r.width, r.height));
                            let bandwidth = v.bandwidth;
                            VariantInfo {
                                url: resolve(&v.uri, base_url),
                                bandwidth,
                                label: variant_label(resolution.as_deref(), bandwidth),
                                resolution,
                                codecs: v.codecs.clone(),
                            }
                        })
                        .collect::<Vec<_>>()
                });
            streams.sort_by(|a, b| b.bandwidth.cmp(&a.bandwidth));
            StreamInfo {
                kind: StreamKind::Master,
                streams,
                segments: 0,
                duration: 0.0,
                encrypted: false,
                is_live: false,
            }
        }
        Playlist::MediaPlaylist(media) => {
            let duration: f64 = media.segments.iter().map(|s| s.duration as f64).sum();
            let encrypted = media.segments.iter().any(|s| {
                matches!(
                    s.key.as_ref().map(|k| &k.method),
                    Some(KeyMethod::AES128) | Some(KeyMethod::SampleAES)
                )
            });
            StreamInfo {
                kind: StreamKind::Media,
                streams: vec![],
                segments: media.segments.len(),
                duration: (duration * 100.0).round() / 100.0,
                encrypted,
                is_live: !media.end_list,
            }
        }
    }
}

/// Pick quality variant URL from a master playlist.
pub fn pick_quality(
    master: &m3u8_rs::MasterPlaylist,
    content: &str,
    quality: &Quality,
    base_url: &str,
) -> String {
    let mut variants = parse_master_manifest(content, base_url)
        .map(|parsed| {
            parsed
                .variants
                .into_iter()
                .map(|variant| variant.info)
                .collect::<Vec<_>>()
        })
        .filter(|variants| !variants.is_empty())
        .unwrap_or_else(|| {
            master
                .variants
                .iter()
                .map(|variant| VariantInfo {
                    url: resolve(&variant.uri, base_url),
                    bandwidth: variant.bandwidth,
                    resolution: variant
                        .resolution
                        .map(|r| format!("{}x{}", r.width, r.height)),
                    label: variant_label(
                        variant
                            .resolution
                            .map(|r| format!("{}x{}", r.width, r.height))
                            .as_deref(),
                        variant.bandwidth,
                    ),
                    codecs: variant.codecs.clone(),
                })
                .collect::<Vec<_>>()
        });

    variants.sort_by(|a, b| b.bandwidth.cmp(&a.bandwidth));
    if variants.is_empty() {
        return base_url.to_string();
    }
    let chosen = match quality {
        Quality::Best => &variants[0],
        Quality::Worst => variants.last().unwrap(),
        Quality::Index(i) => &variants[(*i).min(variants.len() - 1)],
    };
    chosen.url.clone()
}

/// Detect if segments are CMAF/fMP4 format (vs MPEG-TS).
pub fn is_cmaf(media: &MediaPlaylist) -> bool {
    media.segments.iter().any(|s| {
        s.map.is_some() || {
            let uri = s.uri.to_lowercase();
            let uri = uri.split('?').next().unwrap_or("");
            uri.ends_with(".m4s") || uri.ends_with(".cmfv") || uri.ends_with(".cmfa")
        }
    })
}

/// Find default audio rendition URI from a master playlist (for demuxed CMAF).
pub fn find_audio_playlist(
    master: &m3u8_rs::MasterPlaylist,
    content: &str,
    chosen_variant_url: &str,
    base_url: &str,
) -> Option<String> {
    if let Some(parsed) = parse_master_manifest(content, base_url) {
        if let Some(uri) = pick_audio_rendition_from_manifest(&parsed, chosen_variant_url) {
            return Some(uri);
        }
    }

    let audio_groups: HashSet<String> = master
        .variants
        .iter()
        .filter_map(|v| v.audio.clone())
        .collect();
    if audio_groups.is_empty() {
        return None;
    }
    master
        .alternatives
        .iter()
        .find(|a| {
            a.media_type == AlternativeMediaType::Audio
                && audio_groups.contains(&a.group_id)
                && a.uri.is_some()
                && a.default
        })
        .or_else(|| {
            master.alternatives.iter().find(|a| {
                a.media_type == AlternativeMediaType::Audio
                    && audio_groups.contains(&a.group_id)
                    && a.uri.is_some()
            })
        })
        .and_then(|a| a.uri.as_ref().map(|u| resolve(u, base_url)))
}

/// Pre-fetch all unique AES-128 keys referenced in the segment list.
pub async fn prefetch_keys(
    client: &reqwest::Client,
    segments: &[m3u8_rs::MediaSegment],
    base_url: &str,
    retry: u32,
) -> HashMap<String, Vec<u8>> {
    let mut cache: HashMap<String, Vec<u8>> = HashMap::new();
    for seg in segments {
        if let Some(key) = &seg.key {
            if key.method == KeyMethod::AES128 {
                if let Some(uri) = &key.uri {
                    let key_url = resolve(uri, base_url);
                    if !cache.contains_key(&key_url) {
                        if let Ok(bytes) = fetch_bytes_retry(client, &key_url, retry).await {
                            cache.insert(key_url, bytes);
                        }
                    }
                }
            }
        }
    }
    cache
}

pub async fn fetch_bytes_retry(
    client: &reqwest::Client,
    url: &str,
    retry: u32,
) -> Result<Vec<u8>, DownloadError> {
    let mut last_err = DownloadError::Network("no attempts".into());
    for attempt in 0..retry.max(1) {
        match client.get(url).send().await {
            Ok(resp) => match resp.error_for_status() {
                Ok(r) => {
                    return r
                        .bytes()
                        .await
                        .map(|b| b.to_vec())
                        .map_err(|e| DownloadError::Network(e.to_string()));
                }
                Err(e) => last_err = DownloadError::Network(e.to_string()),
            },
            Err(e) => last_err = DownloadError::Network(e.to_string()),
        }
        if attempt + 1 < retry {
            tokio::time::sleep(std::time::Duration::from_secs(2u64.pow(attempt))).await;
        }
    }
    Err(last_err)
}

pub async fn fetch_text_retry(
    client: &reqwest::Client,
    url: &str,
    retry: u32,
) -> Result<String, DownloadError> {
    let bytes = fetch_bytes_retry(client, url, retry).await?;
    String::from_utf8(bytes).map_err(|e| DownloadError::Parse(e.to_string()))
}

fn parse_master_manifest(content: &str, base_url: &str) -> Option<ParsedMasterManifest> {
    let mut parsed = ParsedMasterManifest::default();
    let mut pending_variant_attrs: Option<HashMap<String, String>> = None;

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        if let Some(attrs) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            pending_variant_attrs = Some(parse_attribute_list(attrs));
            continue;
        }

        if let Some(attrs) = line.strip_prefix("#EXT-X-MEDIA:") {
            let attrs = parse_attribute_list(attrs);
            if !attrs
                .get("TYPE")
                .map(|value| value.eq_ignore_ascii_case("AUDIO"))
                .unwrap_or(false)
            {
                continue;
            }
            let (Some(group_id), Some(uri)) = (attrs.get("GROUP-ID"), attrs.get("URI")) else {
                continue;
            };
            parsed.audio_renditions.push(ParsedMasterAudioRendition {
                group_id: group_id.clone(),
                uri: resolve(uri, base_url),
                is_default: attrs
                    .get("DEFAULT")
                    .map(|value| value.eq_ignore_ascii_case("YES"))
                    .unwrap_or(false),
            });
            continue;
        }

        if line.starts_with('#') {
            continue;
        }

        let Some(attrs) = pending_variant_attrs.take() else {
            continue;
        };
        let bandwidth = parse_bandwidth(&attrs);
        let resolution = attrs.get("RESOLUTION").cloned();
        parsed.variants.push(ParsedMasterVariant {
            info: VariantInfo {
                url: resolve(line, base_url),
                bandwidth,
                resolution: resolution.clone(),
                label: variant_label(resolution.as_deref(), bandwidth),
                codecs: attrs.get("CODECS").cloned(),
            },
            audio_group: attrs.get("AUDIO").cloned(),
        });
    }

    if parsed.variants.is_empty() && parsed.audio_renditions.is_empty() {
        None
    } else {
        Some(parsed)
    }
}

fn pick_audio_rendition_from_manifest(
    parsed: &ParsedMasterManifest,
    chosen_variant_url: &str,
) -> Option<String> {
    let selected_group = parsed
        .variants
        .iter()
        .find(|variant| variant.info.url == chosen_variant_url)
        .and_then(|variant| variant.audio_group.clone())
        .or_else(|| {
            let groups: HashSet<String> = parsed
                .variants
                .iter()
                .filter_map(|variant| variant.audio_group.clone())
                .collect();
            if groups.len() == 1 {
                groups.into_iter().next()
            } else {
                None
            }
        });

    if let Some(group_id) = selected_group {
        if let Some(uri) = parsed
            .audio_renditions
            .iter()
            .find(|audio| audio.group_id == group_id && audio.is_default)
            .or_else(|| {
                parsed
                    .audio_renditions
                    .iter()
                    .find(|audio| audio.group_id == group_id)
            })
            .map(|audio| audio.uri.clone())
        {
            return Some(uri);
        }
    }

    if parsed.audio_renditions.len() == 1 {
        return parsed
            .audio_renditions
            .first()
            .map(|audio| audio.uri.clone());
    }

    None
}

fn parse_attribute_list(attrs: &str) -> HashMap<String, String> {
    let mut pairs = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for ch in attrs.chars() {
        match ch {
            '"' => {
                in_quotes = !in_quotes;
                current.push(ch);
            }
            ',' if !in_quotes => {
                if !current.trim().is_empty() {
                    pairs.push(current.trim().to_string());
                }
                current.clear();
            }
            _ => current.push(ch),
        }
    }
    if !current.trim().is_empty() {
        pairs.push(current.trim().to_string());
    }

    pairs
        .into_iter()
        .filter_map(|pair| {
            let (key, value) = pair.split_once('=')?;
            Some((
                key.trim().to_string(),
                value.trim().trim_matches('"').to_string(),
            ))
        })
        .collect()
}

fn parse_bandwidth(attrs: &HashMap<String, String>) -> u64 {
    attrs
        .get("AVERAGE-BANDWIDTH")
        .or_else(|| attrs.get("BANDWIDTH"))
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0)
}

fn variant_label(resolution: Option<&str>, bandwidth: u64) -> String {
    if let Some(resolution) = resolution {
        if let Some(height) = resolution.split('x').nth(1) {
            return format!("{height}p");
        }
    }
    format!("{}kbps", bandwidth / 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_MASTER: &str = r#"#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:AUDIO="audio_0",BANDWIDTH=4735442,FRAME-RATE=29.97,RESOLUTION=1920x1080,AVERAGE-BANDWIDTH=4735442,CODECS="avc1.640028,mp4a.40.2"
0.m3u8
#EXT-X-STREAM-INF:AUDIO="audio_0",BANDWIDTH=3855442,FRAME-RATE=29.97,RESOLUTION=1280x720,AVERAGE-BANDWIDTH=3855442,CODECS="avc1.640028,mp4a.40.2"
1.m3u8
#EXT-X-STREAM-INF:AUDIO="audio_0",BANDWIDTH=2755442,FRAME-RATE=29.97,RESOLUTION=960x540,AVERAGE-BANDWIDTH=2755442,CODECS="avc1.4D4028,mp4a.40.2"
2.m3u8
#EXT-X-STREAM-INF:AUDIO="audio_0",BANDWIDTH=1105478,FRAME-RATE=29.97,RESOLUTION=640x360,AVERAGE-BANDWIDTH=1105478,CODECS="avc1.4D4028,mp4a.40.2"
3.m3u8
#EXT-X-STREAM-INF:AUDIO="audio_0",BANDWIDTH=568678,FRAME-RATE=29.97,RESOLUTION=384x216,AVERAGE-BANDWIDTH=568678,CODECS="avc1.4D4028,mp4a.40.2"
4.m3u8
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0",NAME="und",AUTOSELECT=YES,DEFAULT=YES,FORCED=NO,LANGUAGE="und",URI="5.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0",NAME="und_2",AUTOSELECT=NO,DEFAULT=NO,FORCED=NO,LANGUAGE="und",URI="6.m3u8"
"#;

    const BASE_URL: &str = "https://example.com/master.m3u8";

    // ── playlist_to_info ───────────────────────────────────────────────────────

    #[test]
    fn playlist_to_info_recovers_variants_when_audio_tags_follow_streams() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let info = playlist_to_info(&playlist, SAMPLE_MASTER, BASE_URL);

        assert_eq!(info.kind, StreamKind::Master);
        assert_eq!(info.streams.len(), 5);
        assert_eq!(info.streams[0].url, "https://example.com/0.m3u8");
        assert_eq!(info.streams[4].url, "https://example.com/4.m3u8");
    }

    #[test]
    fn playlist_to_info_sorts_streams_by_bandwidth_descending() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let info = playlist_to_info(&playlist, SAMPLE_MASTER, BASE_URL);

        let bandwidths: Vec<u64> = info.streams.iter().map(|s| s.bandwidth).collect();
        let mut sorted = bandwidths.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(bandwidths, sorted);
    }

    #[test]
    fn playlist_to_info_media_playlist_computes_duration() {
        let media_m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts\n#EXTINF:6.0,\nseg2.ts\n#EXTINF:4.5,\nseg3.ts\n#EXT-X-ENDLIST\n";
        let playlist = parse_playlist(media_m3u8).unwrap();
        let info = playlist_to_info(&playlist, media_m3u8, BASE_URL);

        assert_eq!(info.kind, StreamKind::Media);
        assert_eq!(info.segments, 3);
        assert!((info.duration - 16.5).abs() < 0.01);
        assert!(!info.is_live);
    }

    #[test]
    fn playlist_to_info_detects_live_stream() {
        let live_m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts\n";
        let playlist = parse_playlist(live_m3u8).unwrap();
        let info = playlist_to_info(&playlist, live_m3u8, BASE_URL);

        assert!(info.is_live);
    }

    #[test]
    fn playlist_to_info_detects_encrypted_segments() {
        let enc_m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x0\n#EXTINF:6.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
        let playlist = parse_playlist(enc_m3u8).unwrap();
        let info = playlist_to_info(&playlist, enc_m3u8, BASE_URL);

        assert!(info.encrypted);
    }

    // ── pick_quality ───────────────────────────────────────────────────────────

    #[test]
    fn pick_quality_ignores_audio_tag_parser_regression() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let Playlist::MasterPlaylist(master) = playlist else {
            panic!("expected master playlist");
        };

        assert_eq!(
            pick_quality(&master, SAMPLE_MASTER, &Quality::Best, BASE_URL),
            "https://example.com/0.m3u8"
        );
        assert_eq!(
            pick_quality(&master, SAMPLE_MASTER, &Quality::Worst, BASE_URL),
            "https://example.com/4.m3u8"
        );
    }

    #[test]
    fn pick_quality_index_clamps_to_last_variant() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let Playlist::MasterPlaylist(master) = playlist else {
            panic!("expected master playlist");
        };

        // Index 999 out of 5 variants → falls back to last (worst quality)
        let result = pick_quality(&master, SAMPLE_MASTER, &Quality::Index(999), BASE_URL);
        assert_eq!(result, "https://example.com/4.m3u8");
    }

    #[test]
    fn pick_quality_index_0_selects_best() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let Playlist::MasterPlaylist(master) = playlist else {
            panic!("expected master playlist");
        };

        let result = pick_quality(&master, SAMPLE_MASTER, &Quality::Index(0), BASE_URL);
        assert_eq!(result, "https://example.com/0.m3u8");
    }

    // ── find_audio_playlist ───────────────────────────────────────────────────

    #[test]
    fn find_audio_playlist_recovers_default_audio_rendition() {
        let playlist = parse_playlist(SAMPLE_MASTER).unwrap();
        let Playlist::MasterPlaylist(master) = playlist else {
            panic!("expected master playlist");
        };
        let chosen = pick_quality(&master, SAMPLE_MASTER, &Quality::Best, BASE_URL);

        assert_eq!(
            find_audio_playlist(&master, SAMPLE_MASTER, &chosen, BASE_URL),
            Some("https://example.com/5.m3u8".into())
        );
    }

    #[test]
    fn find_audio_playlist_returns_none_for_media_playlist_without_audio() {
        let media_m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
        let playlist = parse_playlist(media_m3u8).unwrap();
        let Playlist::MediaPlaylist(_) = &playlist else {
            panic!("expected media playlist");
        };
        // build a stub master with no audio
        let master_m3u8 = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nstream.m3u8\n";
        let Playlist::MasterPlaylist(master) = parse_playlist(master_m3u8).unwrap() else {
            panic!("expected master playlist");
        };

        assert_eq!(
            find_audio_playlist(&master, master_m3u8, "https://example.com/stream.m3u8", BASE_URL),
            None
        );
    }

    // ── resolve ────────────────────────────────────────────────────────────────

    #[test]
    fn resolve_returns_absolute_http_url_unchanged() {
        assert_eq!(
            resolve("https://cdn.example.com/stream.m3u8", BASE_URL),
            "https://cdn.example.com/stream.m3u8"
        );
    }

    #[test]
    fn resolve_returns_absolute_http_non_https_unchanged() {
        assert_eq!(
            resolve("http://cdn.example.com/stream.m3u8", BASE_URL),
            "http://cdn.example.com/stream.m3u8"
        );
    }

    #[test]
    fn resolve_resolves_relative_uri_against_base() {
        assert_eq!(
            resolve("0.m3u8", BASE_URL),
            "https://example.com/0.m3u8"
        );
    }

    #[test]
    fn resolve_resolves_path_relative_uri() {
        assert_eq!(
            resolve("segments/seg1.ts", "https://example.com/hls/master.m3u8"),
            "https://example.com/hls/segments/seg1.ts"
        );
    }

    #[test]
    fn resolve_resolves_parent_relative_uri() {
        assert_eq!(
            resolve("../other/seg1.ts", "https://example.com/hls/v2/master.m3u8"),
            "https://example.com/hls/other/seg1.ts"
        );
    }

    #[test]
    fn resolve_returns_uri_unchanged_when_base_is_invalid() {
        assert_eq!(resolve("relative.m3u8", "not-a-url"), "relative.m3u8");
    }

    // ── parse_attribute_list (tested indirectly via public functions) ──────────

    #[test]
    fn parse_attribute_list_handles_quoted_values_with_commas() {
        // Commas inside quotes must not split the attribute list.
        // Test via playlist_to_info which internally calls parse_attribute_list.
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"avc1.640028,mp4a.40.2\"\nstream.m3u8\n";
        let playlist = parse_playlist(master).unwrap();
        let info = playlist_to_info(&playlist, master, BASE_URL);

        assert_eq!(info.streams.len(), 1);
        assert_eq!(
            info.streams[0].codecs.as_deref(),
            Some("avc1.640028,mp4a.40.2")
        );
    }

    // ── variant_label / parse_bandwidth ───────────────────────────────────────

    #[test]
    fn variant_label_uses_resolution_height() {
        assert_eq!(variant_label(Some("1920x1080"), 5000000), "1080p");
        assert_eq!(variant_label(Some("1280x720"), 3000000), "720p");
        assert_eq!(variant_label(Some("640x360"), 1000000), "360p");
    }

    #[test]
    fn variant_label_falls_back_to_kbps_without_resolution() {
        assert_eq!(variant_label(None, 5000000), "5000kbps");
        assert_eq!(variant_label(None, 1500000), "1500kbps");
    }

    #[test]
    fn parse_bandwidth_prefers_average_bandwidth() {
        let mut attrs = HashMap::new();
        attrs.insert("BANDWIDTH".to_string(), "5000000".to_string());
        attrs.insert("AVERAGE-BANDWIDTH".to_string(), "4500000".to_string());

        assert_eq!(parse_bandwidth(&attrs), 4500000);
    }

    #[test]
    fn parse_bandwidth_falls_back_to_bandwidth_key() {
        let mut attrs = HashMap::new();
        attrs.insert("BANDWIDTH".to_string(), "3000000".to_string());

        assert_eq!(parse_bandwidth(&attrs), 3000000);
    }

    #[test]
    fn parse_bandwidth_returns_zero_when_missing() {
        assert_eq!(parse_bandwidth(&HashMap::new()), 0);
    }

    // ── is_cmaf ────────────────────────────────────────────────────────────────

    #[test]
    fn is_cmaf_detects_m4s_segments() {
        let m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg_000001.m4s\n#EXT-X-ENDLIST\n";
        let Playlist::MediaPlaylist(media) = parse_playlist(m3u8).unwrap() else {
            panic!("expected media playlist");
        };
        assert!(is_cmaf(&media));
    }

    #[test]
    fn is_cmaf_detects_m4s_with_query_params() {
        let m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg_000001.m4s?token=abc\n#EXT-X-ENDLIST\n";
        let Playlist::MediaPlaylist(media) = parse_playlist(m3u8).unwrap() else {
            panic!("expected media playlist");
        };
        assert!(is_cmaf(&media));
    }

    #[test]
    fn is_cmaf_returns_false_for_ts_segments() {
        let m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg_000001.ts\n#EXT-X-ENDLIST\n";
        let Playlist::MediaPlaylist(media) = parse_playlist(m3u8).unwrap() else {
            panic!("expected media playlist");
        };
        assert!(!is_cmaf(&media));
    }
}
