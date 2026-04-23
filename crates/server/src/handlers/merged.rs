use std::collections::HashMap;

use axum::{
    extract::{Path as AxumPath, State},
    http::{header, StatusCode},
    response::{IntoResponse, Json},
};
use sha2::{Digest, Sha256};

use crate::state::AppState;
use crate::types::{
    AddChannelRequest, AddGroupRequest, EditChannelRequest, MergedChannel, MergedConfig,
    MergedGroup, OriginLabel, SavedPlaylist,
};

pub(crate) fn channel_stable_id(playlist_id: &str, url: &str) -> String {
    let mut h = Sha256::new();
    h.update(format!("{playlist_id}:{url}"));
    format!("{:x}", h.finalize())[..12].to_string()
}

pub(crate) fn group_stable_id(name: &str) -> String {
    let mut h = Sha256::new();
    h.update(name);
    format!("g_{:x}", h.finalize())[..14].to_string()
}

pub(crate) fn build_merged_view(
    playlists: &HashMap<String, SavedPlaylist>,
    existing: &MergedConfig,
) -> Vec<MergedGroup> {
    let mut sourced: HashMap<String, Vec<MergedChannel>> = HashMap::new();
    let mut sourced_order: Vec<String> = Vec::new();
    let mut sourced_by_id: HashMap<String, MergedChannel> = HashMap::new();

    let mut sorted_playlists: Vec<&SavedPlaylist> = playlists.values().collect();
    sorted_playlists.sort_by(|a, b| {
        a.created_at
            .partial_cmp(&b.created_at)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    for pl in sorted_playlists {
        for ch in &pl.channels {
            let gname = ch.group.clone().unwrap_or_else(|| "Ungrouped".into());
            let cid = channel_stable_id(&pl.id, &ch.url);
            let mc = MergedChannel {
                id: cid.clone(),
                name: ch.name.clone(),
                url: ch.url.clone(),
                enabled: true,
                custom: false,
                group: gname.clone(),
                tvg_logo: ch.logo.clone().unwrap_or_default(),
                tvg_type: ch.tvg_type.clone(),
                source_playlist_id: Some(pl.id.clone()),
                source_playlist_name: Some(pl.name.clone()),
                origin_id: None,
                origin_label: None,
            };
            if !sourced.contains_key(&gname) {
                sourced_order.push(gname.clone());
            }
            sourced.entry(gname).or_default().push(mc.clone());
            sourced_by_id.insert(cid, mc);
        }
    }

    let sync_origin = |c: &mut MergedChannel| {
        let Some(ref oid) = c.origin_id.clone() else {
            return;
        };
        if let Some(src) = sourced_by_id.get(oid) {
            c.name = src.name.clone();
            c.url = src.url.clone();
            c.tvg_logo = src.tvg_logo.clone();
            c.origin_label = Some(OriginLabel {
                group_name: src.group.clone(),
                channel_name: src.name.clone(),
                source_playlist_name: src.source_playlist_name.clone().unwrap_or_default(),
                alive: true,
            });
        } else {
            c.origin_label = Some(OriginLabel {
                group_name: String::new(),
                channel_name: c.name.clone(),
                source_playlist_name: String::new(),
                alive: false,
            });
        }
    };

    let known_names: std::collections::HashSet<_> =
        existing.groups.iter().map(|g| g.name.clone()).collect();
    let mut result = Vec::new();
    for eg in &existing.groups {
        if eg.custom {
            let mut g = eg.clone();
            for ch in g.channels.iter_mut() {
                sync_origin(ch);
            }
            result.push(g);
        } else if let Some(fresh) = sourced.get(&eg.name) {
            let fresh_map: HashMap<_, _> = fresh.iter().map(|c| (c.id.clone(), c)).collect();
            let mut ng = eg.clone();
            let mut seen_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
            ng.channels = eg
                .channels
                .iter()
                .filter_map(|c| {
                    seen_ids.insert(c.id.clone());
                    if c.custom {
                        let mut nc = c.clone();
                        sync_origin(&mut nc);
                        Some(nc)
                    } else if let Some(fresh_ch) = fresh_map.get(&c.id) {
                        let mut nc = (*fresh_ch).clone();
                        nc.enabled = c.enabled;
                        Some(nc)
                    } else {
                        None
                    }
                })
                .collect();
            for fresh_ch in fresh {
                if !seen_ids.contains(&fresh_ch.id) {
                    ng.channels.push(fresh_ch.clone());
                }
            }
            result.push(ng);
        }
    }
    for name in &sourced_order {
        if !known_names.contains(name) {
            let chs = sourced.get(name).cloned().unwrap_or_default();
            result.push(MergedGroup {
                id: group_stable_id(name),
                name: name.clone(),
                enabled: true,
                custom: false,
                channels: chs,
            });
        }
    }
    result
}

pub(crate) async fn get_all_playlists(State(state): State<AppState>) -> impl IntoResponse {
    let playlists = state.playlists.read().await;
    let existing = state.merged_config.read().await;
    let groups = build_merged_view(&playlists, &existing);
    drop(existing);
    drop(playlists);
    Json(serde_json::json!({"groups": groups}))
}

pub(crate) async fn put_all_playlists(
    State(state): State<AppState>,
    Json(body): Json<MergedConfig>,
) -> impl IntoResponse {
    *state.merged_config.write().await = body;
    state.save_merged_config().await;
    Json(serde_json::json!({"ok": true}))
}

pub(crate) async fn add_custom_group(
    State(state): State<AppState>,
    Json(body): Json<AddGroupRequest>,
) -> impl IntoResponse {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"name required"})),
        )
            .into_response();
    }
    {
        let mc = state.merged_config.read().await;
        if mc.groups.iter().any(|g| g.name == name) {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail":"Group already exists"})),
            )
                .into_response();
        }
    }
    let group = MergedGroup {
        id: uuid::Uuid::new_v4().to_string(),
        name: name.clone(),
        enabled: true,
        custom: true,
        channels: vec![],
    };
    state.merged_config.write().await.groups.push(group.clone());
    state.save_merged_config().await;
    (
        StatusCode::CREATED,
        Json(serde_json::json!({"ok": true, "group": group})),
    )
        .into_response()
}

pub(crate) async fn delete_custom_group(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    let Some(g) = mc.groups.iter().find(|g| g.id == id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };
    if !g.custom {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Cannot delete sourced group"})),
        )
            .into_response();
    }
    mc.groups.retain(|g| g.id != id);
    drop(mc);
    state.save_merged_config().await;
    Json(serde_json::json!({"ok": true})).into_response()
}

pub(crate) async fn add_custom_channel(
    State(state): State<AppState>,
    Json(body): Json<AddChannelRequest>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    let Some(group) = mc.groups.iter_mut().find(|g| g.id == body.group_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Group not found"})),
        )
            .into_response();
    };
    let ch = MergedChannel {
        id: channel_stable_id(&body.group_id, &body.url),
        name: body.name,
        url: body.url,
        enabled: true,
        custom: true,
        group: group.name.clone(),
        tvg_logo: body.tvg_logo,
        tvg_type: None,
        source_playlist_id: None,
        source_playlist_name: None,
        origin_id: None,
        origin_label: None,
    };
    group.channels.push(ch.clone());
    drop(mc);
    state.save_merged_config().await;
    (
        StatusCode::CREATED,
        Json(serde_json::json!({"ok": true, "channel": ch})),
    )
        .into_response()
}

pub(crate) async fn edit_custom_channel(
    State(state): State<AppState>,
    AxumPath(ch_id): AxumPath<String>,
    Json(body): Json<EditChannelRequest>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    for group in mc.groups.iter_mut() {
        for ch in group.channels.iter_mut() {
            if ch.id == ch_id {
                if let Some(e) = body.enabled {
                    ch.enabled = e;
                }
                if let Some(ref n) = body.name {
                    if !n.trim().is_empty() {
                        ch.name = n.clone();
                    }
                }
                if let Some(ref g) = body.group {
                    ch.group = g.clone();
                }
                let result = Json(serde_json::json!({"ok": true}));
                drop(mc);
                state.save_merged_config().await;
                return result.into_response();
            }
        }
    }
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({"detail":"Channel not found"})),
    )
        .into_response()
}

pub(crate) async fn delete_custom_channel(
    State(state): State<AppState>,
    AxumPath(ch_id): AxumPath<String>,
) -> impl IntoResponse {
    let mut mc = state.merged_config.write().await;
    for group in mc.groups.iter_mut() {
        let before = group.channels.len();
        group.channels.retain(|c| c.id != ch_id);
        if group.channels.len() < before {
            drop(mc);
            state.save_merged_config().await;
            return Json(serde_json::json!({"ok": true})).into_response();
        }
    }
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({"detail":"Not found"})),
    )
        .into_response()
}

pub(crate) async fn export_m3u(State(state): State<AppState>) -> impl IntoResponse {
    let playlists = state.playlists.read().await;
    let existing = state.merged_config.read().await;
    let groups = build_merged_view(&playlists, &existing);
    drop(existing);
    drop(playlists);

    let mut lines = vec!["#EXTM3U x-tvg-url=\"\"".to_string()];
    for group in groups.iter().filter(|g| g.enabled) {
        for ch in group.channels.iter().filter(|c| c.enabled) {
            let logo = if ch.tvg_logo.is_empty() {
                String::new()
            } else {
                format!(r#" tvg-logo="{}""#, ch.tvg_logo)
            };
            lines.push(format!(
                r#"#EXTINF:-1 tvg-name="{}" tvg-id=""{} group-title="{}",{}"#,
                ch.name, logo, group.name, ch.name
            ));
            lines.push(ch.url.clone());
        }
    }
    (
        [(header::CONTENT_TYPE, "application/x-mpegurl; charset=utf-8")],
        lines.join("\n"),
    )
        .into_response()
}
