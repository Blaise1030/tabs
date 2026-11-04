//! The daemon's shared state, and the router that puts every route behind the guard.

use crate::{board, chat, files, sessions, settings, upload, web};
use axum::{Router, middleware};
use rusqlite::Connection;
use sessions::Session;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

/// The database is the source of truth for which sessions exist; `live`
/// holds the ones with a running shell. Lock order: `starting` (one
/// session's turn), then `live`, then `db`, then a session's `output`
/// (as `flush` takes them).
#[derive(Clone)]
pub(crate) struct AppState {
    pub(crate) db: Arc<Mutex<Connection>>,
    pub(crate) live: Arc<Mutex<HashMap<String, Arc<Session>>>>,
    /// Sessions whose shell is being started, restarted or closed.
    pub(crate) starting: Arc<sessions::pty::Starting>,
    pub(crate) db_path: Arc<str>,
    pub(crate) started: std::time::Instant,
    /// Bearer token Tabs / hooks must present.
    pub(crate) token: Arc<str>,
    pub(crate) origins: Arc<[String]>,
    /// This daemon's own address, given to shells as `TABSH_URL`.
    pub(crate) self_url: Arc<str>,
    /// Card status changes, for `/api/board/events`.
    pub(crate) events: tokio::sync::broadcast::Sender<crate::board::BoardEvent>,
    /// Live ACP chats for UI-mode cards, one per card at most.
    pub(crate) chats: crate::chat::ChatManager,
    /// The port this daemon was asked to listen on.
    pub(crate) port: u16,
}

/// Builds the app router with all routes and the guard middleware applied.
pub(crate) fn router(state: AppState) -> Router {
    Router::new()
        .merge(web::routes())
        .merge(sessions::routes())
        .merge(chat::routes())
        .merge(board::routes())
        .merge(files::routes())
        .merge(settings::routes())
        .merge(upload::routes())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            web::guard::guard,
        ))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{loopback_peer, test_state};
    use axum::http::{Method, StatusCode};

    #[tokio::test]
    async fn every_route_is_guarded() {
        use tower::ServiceExt;

        let state = test_state();

        // Routes that require a token: each returns 401 with Origin but no token.
        let guarded_routes: &[(Method, &str)] = &[
            (Method::GET, "/"),
            (Method::GET, "/open"),
            (Method::GET, "/api/sessions"),
            (Method::POST, "/api/sessions"),
            (Method::PUT, "/api/sessions/order"),
            (Method::PATCH, "/api/sessions/x"),
            (Method::DELETE, "/api/sessions/x"),
            (Method::PATCH, "/api/sessions/x/status"),
            (Method::PATCH, "/api/sessions/x/prompt"),
            (Method::GET, "/api/sessions/x/chat"),
            (Method::GET, "/api/sessions/x/chat/stream"),
            (Method::POST, "/api/sessions/x/chat/message"),
            (Method::POST, "/api/sessions/x/chat/stop"),
            (Method::POST, "/api/sessions/x/chat/approve"),
            (Method::GET, "/api/sessions/x/chat/models"),
            (Method::POST, "/api/sessions/x/chat/model"),
            (Method::GET, "/api/sessions/x/chat/modes"),
            (Method::POST, "/api/sessions/x/chat/mode"),
            (Method::GET, "/api/sessions/x/chat/approvals"),
            (Method::POST, "/api/sessions/x/chat/approvals"),
            (Method::POST, "/api/sessions/x/chat/start"),
            (Method::PATCH, "/api/board/agents/x/status"),
            (Method::GET, "/api/board/events"),
            (Method::GET, "/api/settings"),
            (Method::PUT, "/api/settings"),
            (Method::GET, "/api/about"),
            (Method::POST, "/api/uploads?name=a"),
            (Method::GET, "/api/files/folders?path=/a"),
            (Method::GET, "/api/files/tree?session=x"),
            (Method::GET, "/api/files/watch?session=x"),
            (Method::GET, "/ws?id=x"),
            (Method::GET, "/nope"),
        ];

        // All guarded routes with Origin but no token → 401
        for (method, path) in guarded_routes {
            let req = axum::http::Request::builder()
                .method(method.clone())
                .uri(*path)
                .header("Host", "127.0.0.1:7681")
                .header("Origin", "https://tabsh.cc")
                .extension(loopback_peer())
                .body(axum::body::Body::empty())
                .unwrap();
            let app = router(state.clone());
            let res = app.oneshot(req).await.unwrap();
            assert_eq!(
                res.status(),
                StatusCode::UNAUTHORIZED,
                "expected 401 for {} {}",
                method,
                path
            );
        }

        // Every privileged route requires a token when no Origin header,
        // as a direct call (landing page routes aside).
        for (method, path) in guarded_routes {
            let req = axum::http::Request::builder()
                .method(method.clone())
                .uri(*path)
                .header("Host", "127.0.0.1:7681")
                .extension(loopback_peer())
                .body(axum::body::Body::empty())
                .unwrap();
            let app = router(state.clone());
            let res = app.oneshot(req).await.unwrap();
            // The landing paths are the only exceptions, and only as GET/HEAD.
            let page = (method == Method::GET || method == Method::HEAD)
                && matches!(*path, "/" | "/open");
            if page {
                assert_ne!(
                    res.status(),
                    StatusCode::UNAUTHORIZED,
                    "{} {} without Origin should reach the page",
                    method,
                    path
                );
            } else {
                assert_eq!(
                    res.status(),
                    StatusCode::UNAUTHORIZED,
                    "expected 401 for {} {} without Origin or token",
                    method,
                    path
                );
            }
        }

        // File API requires token when no Origin header
        for path in &["/api/files/tree?session=x", "/api/files/watch?session=x"] {
            let req = axum::http::Request::builder()
                .method(Method::GET)
                .uri(*path)
                .header("Host", "127.0.0.1:7681")
                .extension(loopback_peer())
                .body(axum::body::Body::empty())
                .unwrap();
            let app = router(state.clone());
            let res = app.oneshot(req).await.unwrap();
            assert_eq!(
                res.status(),
                StatusCode::UNAUTHORIZED,
                "GET {} without Origin should be 401",
                path
            );
        }

        // Foreign origins are rejected
        let req = axum::http::Request::builder()
            .method(Method::GET)
            .uri("/api/sessions")
            .header("Host", "127.0.0.1:7681")
            .header("Origin", "https://evil.example")
            .extension(loopback_peer())
            .body(axum::body::Body::empty())
            .unwrap();
        let app = router(state.clone());
        let res = app.oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::FORBIDDEN,
            "GET /api/sessions with foreign Origin should be 403"
        );

        // Non-address hostnames are rejected (DNS rebinding protection)
        let req = axum::http::Request::builder()
            .method(Method::GET)
            .uri("/api/sessions")
            .header("Host", "evil.example")
            .header("Origin", "https://tabsh.cc")
            .extension(loopback_peer())
            .body(axum::body::Body::empty())
            .unwrap();
        let app = router(state.clone());
        let res = app.oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::FORBIDDEN,
            "GET /api/sessions with non-address Host should be 403"
        );

        // Unrouted paths with valid auth return 404
        let req = axum::http::Request::builder()
            .method(Method::GET)
            .uri("/nope")
            .header("Host", "127.0.0.1:7681")
            .header("Origin", "https://tabsh.cc")
            .header("Authorization", "Bearer t0k3n")
            .extension(loopback_peer())
            .body(axum::body::Body::empty())
            .unwrap();
        let app = router(state);
        let res = app.oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::NOT_FOUND,
            "GET /nope with valid auth should be 404"
        );
    }
}
