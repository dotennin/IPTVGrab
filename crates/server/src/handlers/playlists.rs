use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};

use crate::handlers::health::trigger_health_check;
use crate::helpers::{fetch_m3u, parse_m3u_text};
use crate::state::AppState;
use crate::types::{AddPlaylistRequest, EditPlaylistRequest, SavedPlaylist};

pub(crate) async fn list_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    let list: Vec<&SavedPlaylist> = pl.values().collect();
    Json(serde_json::to_value(&list).unwrap())
}

pub(crate) async fn add_playlist(
    State(state): State<AppState>,
    Json(body): Json<AddPlaylistRequest>,
) -> impl IntoResponse {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();

    let channels = if let Some(raw) = body.raw {
        parse_m3u_text(&raw)
    } else if let Some(ref url) = body.url {
        match fetch_m3u(url).await {
            Ok(text) => parse_m3u_text(&text),
            Err(e) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail": e})),
                )
                    .into_response()
            }
        }
    } else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail": "url or raw required"})),
        )
            .into_response();
    };

    let id = uuid::Uuid::new_v4().to_string();
    let channel_count = channels.len();
    let pl = SavedPlaylist {
        id: id.clone(),
        name: body.name,
        url: body.url,
        channels,
        created_at: now,
        updated_at: now,
        channel_count,
    };
    state.playlists.write().await.insert(id.clone(), pl.clone());
    state.save_playlists().await;
    let urls: Vec<String> = pl.channels.iter().map(|c| c.url.clone()).collect();
    trigger_health_check(state, urls, false).await;
    (
        StatusCode::CREATED,
        Json(serde_json::to_value(&pl).unwrap()),
    )
        .into_response()
}

pub(crate) async fn get_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    match pl.get(&id) {
        Some(p) => Json(serde_json::to_value(p).unwrap()).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub(crate) async fn delete_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    state.playlists.write().await.remove(&id);
    state.save_playlists().await;
    Json(serde_json::json!({"status":"deleted"}))
}

pub(crate) async fn edit_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
    Json(body): Json<EditPlaylistRequest>,
) -> impl IntoResponse {
    let mut pl = state.playlists.write().await;
    let Some(entry) = pl.get_mut(&id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    if let Some(name) = body.name.filter(|s| !s.trim().is_empty()) {
        entry.name = name;
    }
    if let Some(url) = body.url {
        entry.url = if url.trim().is_empty() {
            None
        } else {
            Some(url)
        };
    }
    let result = serde_json::json!({"ok": true, "name": entry.name, "url": entry.url});
    drop(pl);
    state.save_playlists().await;
    Json(result).into_response()
}

pub(crate) async fn refresh_playlist(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let url = {
        let pl = state.playlists.read().await;
        let Some(entry) = pl.get(&id) else {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"Not found"})),
            )
                .into_response();
        };
        match entry.url.clone() {
            Some(u) => u,
            None => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Playlist has no URL"})),
                )
                    .into_response()
            }
        }
    };

    let text = match fetch_m3u(&url).await {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail": e})),
            )
                .into_response()
        }
    };

    let channels = parse_m3u_text(&text);
    if channels.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"No channels found"})),
        )
            .into_response();
    }

    let count = channels.len();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    {
        let mut pl = state.playlists.write().await;
        if let Some(entry) = pl.get_mut(&id) {
            entry.channels = channels;
            entry.channel_count = count;
            entry.updated_at = now;
        }
    }
    state.save_playlists().await;
    let urls: Vec<String> = {
        let pl = state.playlists.read().await;
        pl.get(&id)
            .map(|p| p.channels.iter().map(|c| c.url.clone()).collect())
            .unwrap_or_default()
    };
    trigger_health_check(state, urls, false).await;
    Json(serde_json::json!({"channel_count": count})).into_response()
}

pub(crate) async fn list_channels(State(state): State<AppState>) -> impl IntoResponse {
    let pl = state.playlists.read().await;
    let channels: Vec<serde_json::Value> = pl
        .values()
        .flat_map(|p| {
            p.channels.iter().map(|ch| {
                serde_json::json!({
                    "name": ch.name,
                    "url": ch.url,
                    "group": ch.group,
                    "logo": ch.logo,
                    "tvg_type": ch.tvg_type,
                    "playlist_id": p.id,
                    "playlist_name": p.name,
                })
            })
        })
        .collect();
    Json(channels)
}

pub(crate) async fn refresh_all_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let ids_urls: Vec<(String, String)> = {
        let pl = state.playlists.read().await;
        pl.values()
            .filter_map(|p| p.url.as_ref().map(|u| (p.id.clone(), u.clone())))
            .collect()
    };

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let mut errors: Vec<String> = Vec::new();

    for (id, url) in ids_urls {
        match fetch_m3u(&url).await {
            Ok(text) => {
                let channels = parse_m3u_text(&text);
                if !channels.is_empty() {
                    let count = channels.len();
                    let mut pl = state.playlists.write().await;
                    if let Some(entry) = pl.get_mut(&id) {
                        entry.channels = channels;
                        entry.channel_count = count;
                        entry.updated_at = now;
                    }
                }
            }
            Err(e) => errors.push(e),
        }
    }
    state.save_playlists().await;
    let urls: Vec<String> = {
        let pl = state.playlists.read().await;
        pl.values()
            .flat_map(|p| p.channels.iter().map(|c| c.url.clone()))
            .collect()
    };
    trigger_health_check(state, urls, false).await;
    Json(serde_json::json!({"ok": true, "errors": errors})).into_response()
}
