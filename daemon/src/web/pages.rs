//! Minimal landing page. No browser open, no embedded UI.

use axum::{
    extract::State,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};

use crate::AppState;

pub(crate) async fn root() -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/plain; charset=utf-8"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        "tabsh daemon (Tabs) — API only. Use the Tabs app.\n",
    )
        .into_response()
}

pub(crate) async fn open_app() -> Response {
    root().await
}

pub(crate) async fn about(
    State(st): State<AppState>,
) -> Result<axum::Json<serde_json::Value>, axum::http::StatusCode> {
    let (running, total) = crate::sessions::counts(&st).map_err(crate::error::internal_error)?;
    Ok(axum::Json(serde_json::json!({
        "version": env!("CARGO_PKG_VERSION"),
        "shell": crate::sessions::pty::user_shell(),
        "state_path": &*st.db_path,
        "uptime_secs": st.started.elapsed().as_secs(),
        "sessions_running": running,
        "sessions_total": total,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn root_is_plain_text() {
        let res = root().await;
        assert_eq!(res.status(), StatusCode::OK);
    }
}
