//! Loopback HTTP surface for the daemon: about + a tiny root page.
//! Session UI lives in Tabs (native), not in an embedded web app.

pub(crate) mod guard;
pub(crate) mod pages;

use axum::{Router, routing::get};

use crate::AppState;
use pages::{about, open_app, root};

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/", get(root))
        .route("/open", get(open_app))
        .route("/api/about", get(about))
}
