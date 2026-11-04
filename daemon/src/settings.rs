//! The page's preferences (theme, font, keybindings…), stored as one JSON object.

use crate::{AppState, error::internal_error};
use axum::{Json, Router, extract::State, http::StatusCode, routing::get};
use rusqlite::{OptionalExtension, params};

pub(crate) fn routes() -> Router<AppState> {
    Router::new().route("/api/settings", get(get_settings).put(put_settings))
}

async fn get_settings(State(st): State<AppState>) -> Result<Json<serde_json::Value>, StatusCode> {
    let value: Option<String> = st
        .db
        .lock()
        .unwrap()
        .query_row("SELECT value FROM settings WHERE id = 1", [], |r| r.get(0))
        .optional()
        .map_err(internal_error)?;
    let settings = value
        .and_then(|v| serde_json::from_str(&v).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    Ok(Json(settings))
}

async fn put_settings(
    State(st): State<AppState>,
    Json(settings): Json<serde_json::Value>,
) -> StatusCode {
    if !settings.is_object() {
        return StatusCode::BAD_REQUEST;
    }
    match st.db.lock().unwrap().execute(
        "INSERT INTO settings (id, value) VALUES (1, ?1)
         ON CONFLICT (id) DO UPDATE SET value = excluded.value",
        params![settings.to_string()],
    ) {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => internal_error(e),
    }
}
