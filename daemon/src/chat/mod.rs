//! ACP chat: the daemon-side client for UI-mode cards.
//!
//! The browser never speaks ACP; the daemon owns the ACP client, the
//! per-card lifecycle (`manager`) and the on-disk transcript
//! (`transcript`), and serves `UiChunk`s over the guarded chat routes.

pub(crate) mod acp;
pub(crate) mod manager;
pub(crate) mod models;
pub(crate) mod normalize;
pub(crate) mod routes;
pub(crate) mod transcript;

pub(crate) use manager::{ChatManager, PtyClaim};

use crate::AppState;
use axum::Router;

/// The chat routes, merged behind the guard in `state::router()`.
pub(crate) fn routes() -> Router<AppState> {
    routes::routes()
}
