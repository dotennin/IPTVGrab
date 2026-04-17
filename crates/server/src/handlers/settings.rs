use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;

use crate::state::AppState;

/// GET /api/settings — return the current server-wide settings.
pub(crate) async fn get_settings(State(state): State<AppState>) -> impl IntoResponse {
    let s = state.app_settings.read().await;
    Json(serde_json::json!({
        "use_proxy": s.use_proxy,
        "health_only_filter": s.health_only_filter,
        "recent_limit": s.recent_limit,
        "auto_fullscreen": s.auto_fullscreen,
    }))
    .into_response()
}

#[derive(Debug, Deserialize)]
pub(crate) struct PatchSettings {
    pub(crate) use_proxy: Option<bool>,
    pub(crate) health_only_filter: Option<bool>,
    pub(crate) recent_limit: Option<usize>,
    pub(crate) auto_fullscreen: Option<bool>,
}

/// PATCH /api/settings — merge-update settings and persist.
pub(crate) async fn patch_settings(
    State(state): State<AppState>,
    Json(body): Json<PatchSettings>,
) -> impl IntoResponse {
    {
        let mut s = state.app_settings.write().await;
        if let Some(v) = body.use_proxy {
            s.use_proxy = v;
        }
        if let Some(v) = body.health_only_filter {
            s.health_only_filter = v;
        }
        if let Some(v) = body.recent_limit {
            s.recent_limit = v.clamp(1, 200);
        }
        if let Some(v) = body.auto_fullscreen {
            s.auto_fullscreen = v;
        }
    }
    state.save_app_settings().await;
    let s = state.app_settings.read().await;
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "use_proxy": s.use_proxy,
            "health_only_filter": s.health_only_filter,
            "recent_limit": s.recent_limit,
            "auto_fullscreen": s.auto_fullscreen,
        })),
    )
        .into_response()
}
