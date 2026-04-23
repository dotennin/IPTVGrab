use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use m3u8_core::parser::resolve;
use url::form_urlencoded;

use crate::state::AppState;
use crate::types::{WatchCacheEntry, WatchProxyQuery};

pub(crate) async fn watch_probe(
    State(state): State<AppState>,
    Query(query): Query<WatchProxyQuery>,
) -> impl IntoResponse {
    if !query.url.starts_with("http://") && !query.url.starts_with("https://") {
        return Json(serde_json::json!({"kind": "unknown", "content_type": ""})).into_response();
    }

    let resp = state
        .probe_client
        .get(&query.url)
        .timeout(std::time::Duration::from_secs(8))
        .send()
        .await;

    let (ct, final_url) = match resp {
        Ok(r) => {
            if r.status().is_redirection() {
                let location = r
                    .headers()
                    .get(header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| query.url.clone());
                let ct = infer_watch_content_type(&location);
                (ct, location)
            } else {
                let final_url = r.url().to_string();
                let ct = r
                    .headers()
                    .get(header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| infer_watch_content_type(&final_url));
                (ct, final_url)
            }
        }
        Err(_) => (infer_watch_content_type(&query.url), query.url.clone()),
    };

    let orig = query.url.to_lowercase();
    let fin = final_url.to_lowercase();
    let kind = if content_type_is_flv(&ct) || fin.contains(".flv") || orig.contains(".flv") {
        "flv"
    } else if ct.contains("mpegurl")
        || ct.contains("x-mpegurl")
        || fin.contains(".m3u8")
        || orig.contains(".m3u8")
    {
        "hls"
    } else {
        "unknown"
    };

    Json(serde_json::json!({"kind": kind, "content_type": ct, "final_url": final_url}))
        .into_response()
}

pub(crate) async fn watch_proxy(
    State(state): State<AppState>,
    Query(query): Query<WatchProxyQuery>,
) -> impl IntoResponse {
    if !query.url.starts_with("http://") && !query.url.starts_with("https://") {
        return (StatusCode::BAD_REQUEST, "Invalid watch URL").into_response();
    }

    if url_is_media_segment(&query.url) {
        let resp = match state.proxy_client.get(&query.url).send().await {
            Ok(r) => r,
            Err(_) => return (StatusCode::BAD_GATEWAY, "Upstream request failed").into_response(),
        };

        let status =
            StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
        if !status.is_success() {
            return Response::builder()
                .status(status)
                .header(header::CACHE_CONTROL, "no-store")
                .body(Body::empty())
                .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response());
        }

        let content_type = resp
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .unwrap_or_else(|| infer_watch_content_type(&query.url));
        let content_length = resp
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());

        let stream = resp.bytes_stream();
        let cache_control = if content_type_is_flv(&content_type) {
            "no-store"
        } else {
            "public, max-age=120"
        };
        let mut builder = Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::CACHE_CONTROL, cache_control);
        if let Some(len) = content_length {
            builder = builder.header(header::CONTENT_LENGTH, len);
        }
        return builder
            .body(Body::from_stream(stream))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
    }

    if query.kind.as_deref() == Some("flv") || _url_is_flv(&query.url) {
        let live_resp = match state.proxy_client.get(&query.url).send().await {
            Ok(r) => r,
            Err(_) => return (StatusCode::BAD_GATEWAY, "FLV stream fetch failed").into_response(),
        };
        if !live_resp.status().is_success() {
            return (StatusCode::BAD_GATEWAY, "Upstream FLV error").into_response();
        }
        let ct = live_resp
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "video/x-flv".to_string());
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, ct)
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from_stream(live_resp.bytes_stream()))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
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

    let effective_url = resp.url().to_string();

    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = resp
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
        .unwrap_or_else(|| infer_watch_content_type(&effective_url));

    if content_type_is_flv(&content_type) {
        if !status.is_success() {
            return (StatusCode::BAD_GATEWAY, "Upstream FLV error").into_response();
        }
        drop(resp);
        let live_resp = match state.proxy_client.get(&query.url).send().await {
            Ok(r) => r,
            Err(_) => return (StatusCode::BAD_GATEWAY, "FLV stream fetch failed").into_response(),
        };
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from_stream(live_resp.bytes_stream()))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
    }

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

    // Nested-master resolution
    let (bytes, effective_url, content_type) = {
        let text_cow = String::from_utf8_lossy(&bytes);
        let should_resolve = is_watch_playlist(&query.url, &content_type, &bytes)
            && is_master_playlist(&text_cow)
            && effective_url != query.url;
        let variant_url = if should_resolve {
            pick_best_variant_url(&text_cow, &effective_url)
        } else {
            None
        };
        drop(text_cow);
        if let Some(vurl) = variant_url {
            match state.http_client.get(&vurl).send().await {
                Ok(vresp) if vresp.status().is_success() => {
                    let ve = vresp.url().to_string();
                    let vct = vresp
                        .headers()
                        .get(header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| infer_watch_content_type(&ve));
                    match vresp.bytes().await {
                        Ok(vb) => (vb, ve, vct),
                        Err(_) => (bytes, effective_url, content_type),
                    }
                }
                _ => (bytes, effective_url, content_type),
            }
        } else {
            (bytes, effective_url, content_type)
        }
    };

    let (body, final_content_type, cache_control, ttl_secs) =
        if is_watch_playlist(&query.url, &content_type, &bytes) {
            let text = String::from_utf8_lossy(&bytes);
            (
                rewrite_watch_playlist(&text, &effective_url).into_bytes(),
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

// ── URL / content-type helpers ────────────────────────────────────────────────

pub(crate) fn unix_now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

pub(crate) fn proxy_watch_url(url: &str) -> String {
    let mut qs = form_urlencoded::Serializer::new(String::new());
    qs.append_pair("url", url);
    format!("/api/watch/proxy?{}", qs.finish())
}

pub(crate) fn infer_watch_content_type(url: &str) -> String {
    if url.contains(".m3u8") {
        "application/vnd.apple.mpegurl".to_string()
    } else if url.contains(".ts") {
        "video/mp2t".to_string()
    } else if url.contains(".m4s") || url.contains(".mp4") {
        "video/mp4".to_string()
    } else if url.contains(".aac") {
        "audio/aac".to_string()
    } else if url.contains(".flv") {
        "video/x-flv".to_string()
    } else {
        "application/octet-stream".to_string()
    }
}

pub(crate) fn is_watch_playlist(url: &str, content_type: &str, body: &[u8]) -> bool {
    url.contains(".m3u8")
        || content_type.contains("mpegurl")
        || content_type.contains("x-mpegurl")
        || body.starts_with(b"#EXTM3U")
}

/// Returns true if the M3U8 text is a pure master playlist.
pub(crate) fn is_master_playlist(text: &str) -> bool {
    text.contains("#EXT-X-STREAM-INF") && !text.contains("#EXTINF")
}

/// Pick the absolute URL of the highest-bandwidth variant in a master playlist.
pub(crate) fn pick_best_variant_url(text: &str, base_url: &str) -> Option<String> {
    let mut best: Option<(u64, String)> = None;
    let mut pending_bw: u64 = 0;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("#EXT-X-STREAM-INF") {
            pending_bw = trimmed
                .split("BANDWIDTH=")
                .nth(1)
                .and_then(|s| s.split([',', '\n', '\r']).next())
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        } else if !trimmed.is_empty() && !trimmed.starts_with('#') {
            let url = resolve(trimmed, base_url);
            let bw = std::mem::take(&mut pending_bw);
            match &best {
                None => best = Some((bw, url)),
                Some((b, _)) if bw > *b => best = Some((bw, url)),
                _ => {}
            }
        }
    }
    best.map(|(_, url)| url)
}

/// Returns true for URLs that are clearly media segments or key files.
pub(crate) fn url_is_media_segment(url: &str) -> bool {
    let path = url.split('?').next().unwrap_or(url).to_lowercase();
    path.ends_with(".ts")
        || path.ends_with(".m4s")
        || path.ends_with(".mp4")
        || path.ends_with(".m4v")
        || path.ends_with(".aac")
        || path.ends_with(".mp3")
        || path.ends_with(".key")
        || path.ends_with(".bin")
        || path.ends_with(".flv")
}

pub(crate) fn content_type_is_flv(ct: &str) -> bool {
    ct.contains("x-flv") || ct.contains("video/flv") || ct.eq_ignore_ascii_case("video/flv")
}

pub(crate) fn _url_is_flv(url: &str) -> bool {
    let path = url.split('?').next().unwrap_or(url);
    path.ends_with(".flv")
}

pub(crate) fn rewrite_watch_playlist(text: &str, base_url: &str) -> String {
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

pub(crate) fn rewrite_watch_uri_attrs(line: &str, base_url: &str) -> String {
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

// Needed for Json extractor used in watch_probe/watch_proxy returns
use axum::response::Json;

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_master_playlist_detects_stream_inf_without_extinf() {
        let master =
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nhttps://cdn.example.com/hi/index.m3u8";
        assert!(is_master_playlist(master));
    }

    #[test]
    fn is_master_playlist_returns_false_for_media_playlist() {
        let media =
            "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:6.0,\nseg0.ts";
        assert!(!is_master_playlist(media));
    }

    #[test]
    fn pick_best_variant_url_chooses_highest_bandwidth() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nhigh.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nmid.m3u8";
        let best = pick_best_variant_url(master, "https://cdn.example.com/live/index.m3u8");
        assert_eq!(
            best,
            Some("https://cdn.example.com/live/high.m3u8".to_string())
        );
    }

    #[test]
    fn pick_best_variant_url_falls_back_to_first_when_no_bandwidth() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1\nstream.m3u8";
        let best = pick_best_variant_url(master, "https://cdn.example.com/live/index.m3u8");
        assert_eq!(
            best,
            Some("https://cdn.example.com/live/stream.m3u8".to_string())
        );
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
    fn rewrite_watch_playlist_handles_absolute_segment_url() {
        let src = "#EXTM3U\n#EXTINF:6.0,\nhttps://cdn.example.com/seg1.ts";
        let out = rewrite_watch_playlist(src, "https://example.com/live/index.m3u8");
        assert!(out.contains("/api/watch/proxy?url=https%3A%2F%2Fcdn.example.com%2Fseg1.ts"));
    }

    #[test]
    fn rewrite_watch_playlist_preserves_extm3u_header_line() {
        let src = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts";
        let out = rewrite_watch_playlist(src, "https://example.com/live/index.m3u8");
        assert!(out.starts_with("#EXTM3U"));
        assert!(out.contains("#EXT-X-TARGETDURATION:6"));
    }
}
