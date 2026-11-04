//! Error types and utilities for the daemon.

use axum::http::StatusCode;

pub(crate) type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub(crate) fn internal_error(e: impl std::fmt::Display) -> StatusCode {
    eprintln!("internal error: {e}");
    StatusCode::INTERNAL_SERVER_ERROR
}
