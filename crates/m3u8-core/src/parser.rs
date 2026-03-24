use std::collections::HashMap;

use m3u8_rs::{AlternativeMediaType, KeyMethod, MediaPlaylist, Playlist};
use url::Url;

use crate::error::DownloadError;
use crate::types::{StreamInfo, StreamKind, VariantInfo};

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
pub fn playlist_to_info(playlist: &Playlist, base_url: &str) -> StreamInfo {
    match playlist {
        Playlist::MasterPlaylist(master) => {
            let mut streams: Vec<VariantInfo> = master
                .variants
                .iter()
                .map(|v| {
                    let res = v.resolution.map(|r| format!("{}x{}", r.width, r.height));
                    let label = match v.resolution {
                        Some(r) => format!("{}p", r.height),
                        None => format!("{}kbps", v.bandwidth / 1000),
                    };
                    VariantInfo {
                        url: resolve(&v.uri, base_url),
                        bandwidth: v.bandwidth,
                        resolution: res,
                        label,
                        codecs: v.codecs.clone(),
                    }
                })
                .collect();
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
    quality: &crate::Quality,
    base_url: &str,
) -> String {
    let mut variants = master.variants.clone();
    variants.sort_by(|a, b| b.bandwidth.cmp(&a.bandwidth));
    if variants.is_empty() {
        return base_url.to_string();
    }
    let chosen = match quality {
        crate::Quality::Best => &variants[0],
        crate::Quality::Worst => variants.last().unwrap(),
        crate::Quality::Index(i) => &variants[(*i).min(variants.len() - 1)],
    };
    resolve(&chosen.uri, base_url)
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
pub fn find_audio_playlist(master: &m3u8_rs::MasterPlaylist, base_url: &str) -> Option<String> {
    let audio_groups: std::collections::HashSet<String> = master
        .variants
        .iter()
        .filter_map(|v| v.audio.clone())
        .collect();
    if audio_groups.is_empty() {
        return None;
    }
    // Prefer DEFAULT=YES
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
