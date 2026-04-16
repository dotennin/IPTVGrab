use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use sha2::{Digest, Sha256};

use crate::state::AppState;
use crate::types::{AddRecentRequest, RecentChannel};

const MAX_RECENTS: usize = 20;

fn recent_id(url: &str) -> String {
    let mut h = Sha256::new();
    h.update(url);
    format!("{:x}", h.finalize())[..12].to_string()
}

fn now_ts() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

pub(crate) async fn list_recents(State(state): State<AppState>) -> impl IntoResponse {
    let recents = state.recents.read().await.clone();
    Json(recents).into_response()
}

pub(crate) async fn add_recent(
    State(state): State<AppState>,
    Json(body): Json<AddRecentRequest>,
) -> impl IntoResponse {
    let url = body.url.trim().to_string();
    if url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"url required"})),
        )
            .into_response();
    }

    let item = RecentChannel {
        id: recent_id(&url),
        name: body.name,
        url,
        tvg_logo: body.tvg_logo,
        group: body.group,
        watched_at: now_ts(),
    };

    {
        let mut recents = state.recents.write().await;
        recents.retain(|existing| existing.id != item.id);
        recents.insert(0, item.clone());
        recents.sort_by(|a, b| {
            b.watched_at
                .partial_cmp(&a.watched_at)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        if recents.len() > MAX_RECENTS {
            recents.truncate(MAX_RECENTS);
        }
    }

    state.save_recents().await;
    Json(item).into_response()
}

pub(crate) async fn delete_recent(
    State(state): State<AppState>,
    AxumPath(id): AxumPath<String>,
) -> impl IntoResponse {
    let removed = {
        let mut recents = state.recents.write().await;
        let before = recents.len();
        recents.retain(|recent| recent.id != id);
        recents.len() != before
    };

    if !removed {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    }

    state.save_recents().await;
    Json(serde_json::json!({"ok": true})).into_response()
}
