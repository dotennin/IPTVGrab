use axum::{
    body::Body,
    extract::State,
    http::{header, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Json, Response},
};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use uuid::Uuid;

use crate::state::AppState;
use crate::types::LoginRequest;

// ── Auth helpers ──────────────────────────────────────────────────────────────

/// Derives a stable, non-reversible export token from the auth password using
/// HMAC-SHA256.  The token is safe to share in URLs (it cannot be used to
/// recover the original password).
pub(crate) fn derive_export_token(password: &str) -> String {
    type HmacSha256 = Hmac<Sha256>;
    let mut mac = HmacSha256::new_from_slice(password.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(b"media-nest-export-v1");
    hex::encode(mac.finalize().into_bytes())
}

// ── Auth middleware ───────────────────────────────────────────────────────────

pub(crate) async fn auth_middleware(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let password = match &state.auth_password {
        None => return next.run(req).await,
        Some(p) => p.clone(),
    };

    let path = req.uri().path().to_string();
    if matches!(path.as_str(), "/login" | "/api/login" | "/api/logout")
        || path.ends_with(".js")
        || path.ends_with(".css")
        || path.ends_with(".ico")
        || path.ends_with(".png")
    {
        return next.run(req).await;
    }

    // Allow ?token=<hmac_token> in the URL for direct-link sharing (e.g. export.m3u).
    let query_token = req
        .uri()
        .query()
        .and_then(|q| {
            q.split('&').find_map(|part| {
                part.strip_prefix("token=")
                    .map(|v| urlencoding_decode(v))
            })
        })
        .unwrap_or_default();
    if !query_token.is_empty() && query_token == derive_export_token(&password) {
        return next.run(req).await;
    }

    let cookie = req
        .headers()
        .get(header::COOKIE)
        .and_then(|c| c.to_str().ok())
        .unwrap_or("");

    let token = cookie
        .split(';')
        .find_map(|part| {
            let p = part.trim();
            p.strip_prefix("session=")
        })
        .unwrap_or("")
        .to_string();

    let sessions = state.sessions.read().await;
    if sessions.contains(&token) {
        drop(sessions);
        return next.run(req).await;
    }

    if path.starts_with("/api/") {
        (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"detail": "Unauthorized"})),
        )
            .into_response()
    } else {
        axum::response::Redirect::to("/login").into_response()
    }
}

/// Percent-decode a query-string value (replaces `+` with space then decodes `%XX`).
pub(crate) fn urlencoding_decode(s: &str) -> String {
    let s = s.replace('+', " ");
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (
                (bytes[i + 1] as char).to_digit(16),
                (bytes[i + 2] as char).to_digit(16),
            ) {
                out.push(((hi << 4) | lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ── Auth handlers ─────────────────────────────────────────────────────────────

pub(crate) async fn login_page() -> impl IntoResponse {
    axum::response::Redirect::to("/login.html")
}

pub(crate) async fn api_login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> impl IntoResponse {
    if let Some(ref pw) = state.auth_password {
        if body.password != *pw {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"detail": "Invalid password"})),
            )
                .into_response();
        }
    }
    let token = Uuid::new_v4().to_string();
    state.sessions.write().await.insert(token.clone());
    let mut response = Json(serde_json::json!({"status": "ok"})).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        format!("session={token}; Path=/; HttpOnly; SameSite=Lax")
            .parse()
            .unwrap(),
    );
    response
}

pub(crate) async fn api_logout(
    State(state): State<AppState>,
    req: Request<Body>,
) -> impl IntoResponse {
    let token = req
        .headers()
        .get(header::COOKIE)
        .and_then(|c| c.to_str().ok())
        .unwrap_or("")
        .split(';')
        .find_map(|p| p.trim().strip_prefix("session="))
        .unwrap_or("")
        .to_string();
    state.sessions.write().await.remove(&token);
    let mut resp = Json(serde_json::json!({"status": "ok"})).into_response();
    resp.headers_mut().insert(
        header::SET_COOKIE,
        "session=; Path=/; Max-Age=0".parse().unwrap(),
    );
    resp
}

pub(crate) async fn auth_status(State(state): State<AppState>) -> impl IntoResponse {
    Json(serde_json::json!({
        "auth_required": state.auth_password.is_some()
    }))
}

/// Returns the HMAC-derived export token for use in shareable export URLs.
/// Requires session auth (enforced by middleware).
pub(crate) async fn get_export_token(State(state): State<AppState>) -> impl IntoResponse {
    match &state.auth_password {
        Some(pw) => Json(serde_json::json!({ "token": derive_export_token(pw) })).into_response(),
        None => Json(serde_json::json!({ "token": null })).into_response(),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_export_token_is_deterministic() {
        let t1 = derive_export_token("secret");
        let t2 = derive_export_token("secret");
        assert_eq!(t1, t2);
        assert!(!t1.is_empty());
    }

    #[test]
    fn derive_export_token_differs_for_different_passwords() {
        let t1 = derive_export_token("password1");
        let t2 = derive_export_token("password2");
        assert_ne!(t1, t2);
    }

    #[test]
    fn urlencoding_decode_handles_percent_encoded() {
        assert_eq!(urlencoding_decode("hello%20world"), "hello world");
        assert_eq!(urlencoding_decode("foo%3Dbar"), "foo=bar");
    }

    #[test]
    fn urlencoding_decode_replaces_plus_with_space() {
        assert_eq!(urlencoding_decode("hello+world"), "hello world");
    }

    #[test]
    fn urlencoding_decode_passthrough_plain_string() {
        assert_eq!(urlencoding_decode("hello"), "hello");
    }
}
