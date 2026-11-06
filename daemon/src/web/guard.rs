//! Request guard middleware for security and origin validation.

use axum::{
    extract::{ConnectInfo, Request},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::net::SocketAddr;

use crate::AppState;
use crate::auth::{self, Credential, presented_token};

/// Origins that may call the API with a bearer token (CORS). TABSH_ORIGINS
/// (comma-separated) replaces this list.
pub(crate) const HOSTED_ORIGINS: &[&str] = &["https://tabsh.cc"];
/// Loopback name printed in URLs instead of a bare `localhost`.
pub(crate) const LOCAL_NAME: &str = "tabsh.localhost";

/// Loopback-only daemon guard: Host must be local/IP; non-loopback peers are
/// refused; `/` and `/open` need no token; everything else needs the bearer.
pub(crate) async fn guard(
    axum::extract::State(st): axum::extract::State<AppState>,
    mut req: Request,
    next: Next,
) -> Response {
    if !host_is_address(req.headers()) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Some(ConnectInfo(peer)) = req.extensions().get::<ConnectInfo<SocketAddr>>().copied() else {
        return StatusCode::FORBIDDEN.into_response();
    };
    let who = presented_token(&req).and_then(|t| resolve_credential(&st, t));
    if let Some(credential) = &who {
        req.extensions_mut().insert(credential.clone());
    }
    let path = req.uri().path();
    if !is_loopback(peer) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let headers = req.headers();
    let Some(origin) = headers.get(header::ORIGIN).cloned() else {
        if !admits_without_origin(req.method(), path, who.as_ref()) {
            return StatusCode::UNAUTHORIZED.into_response();
        }
        if let Some(credential) = &who
            && !auth::allows(credential, req.method(), path)
        {
            return StatusCode::FORBIDDEN.into_response();
        }
        return next.run(req).await;
    };
    // The Host was checked above, so this is a page we served, not a
    // rebound domain or another port on this machine.
    let own = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .is_some_and(|host| origin.as_bytes() == format!("http://{host}").as_bytes());
    if !own && !st.origins.iter().any(|o| origin == o.as_str()) {
        return StatusCode::FORBIDDEN.into_response();
    }

    let mut res = if req.method() == Method::OPTIONS {
        let mut res = StatusCode::NO_CONTENT.into_response();
        let h = res.headers_mut();
        h.insert(
            header::ACCESS_CONTROL_ALLOW_METHODS,
            HeaderValue::from_static("GET, POST, PUT, PATCH, DELETE"),
        );
        h.insert(
            header::ACCESS_CONTROL_ALLOW_HEADERS,
            HeaderValue::from_static("authorization, content-type"),
        );
        h.insert(
            header::ACCESS_CONTROL_MAX_AGE,
            HeaderValue::from_static("600"),
        );
        // Chrome's Private Network Access preflight for public pages reaching localhost.
        h.insert(
            "access-control-allow-private-network",
            HeaderValue::from_static("true"),
        );
        res
    } else if let Some(credential) = &who {
        if !auth::allows(credential, req.method(), path) {
            StatusCode::FORBIDDEN.into_response()
        } else {
            next.run(req).await
        }
    } else {
        StatusCode::UNAUTHORIZED.into_response()
    };
    let h = res.headers_mut();
    h.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin);
    h.insert(header::VARY, HeaderValue::from_static("origin"));
    res
}

/// The pairing token, or a card's own session token from the database.
fn resolve_credential(st: &AppState, presented: &str) -> Option<Credential> {
    if let Some(main) = auth::credential(&st.token, presented) {
        return Some(main);
    }
    let db = st.db.lock().unwrap_or_else(|e| e.into_inner());
    crate::sessions::store::session_id_for_token(&db, presented)
        .map(|id| Credential::Session { id })
}

/// Whether a request with no Origin may pass. Only `/` and `/open` are
/// readable without a token; everything else needs one as a direct call.
fn admits_without_origin(method: &Method, path: &str, credential: Option<&Credential>) -> bool {
    is_page(method, path) || credential.is_some()
}

/// Plain landing pages — read-only, no token.
fn is_page(method: &Method, path: &str) -> bool {
    (method == Method::GET || method == Method::HEAD) && matches!(path, "/" | "/open")
}

pub(crate) fn is_loopback(peer: SocketAddr) -> bool {
    peer.ip().to_canonical().is_loopback()
}

fn host_is_address(headers: &HeaderMap) -> bool {
    let Some(host) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let name = match host.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => host.rsplit_once(':').map_or(host, |(name, _)| name),
    };
    name.eq_ignore_ascii_case("localhost")
        || name.eq_ignore_ascii_case(LOCAL_NAME)
        || name.parse::<std::net::IpAddr>().is_ok()
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::Credential;
    use crate::test_support::{loopback_peer, test_state};
    use axum::{Extension, Router, body::Body, extract::ConnectInfo, routing::get};
    use std::net::SocketAddr;
    use tower::ServiceExt;

    const REMOTE: Option<[u8; 4]> = Some([100, 64, 0, 1]);
    const LOOPBACK: Option<[u8; 4]> = Some([127, 0, 0, 1]);

    fn request(
        method: Method,
        path: &str,
        peer: Option<[u8; 4]>,
        origin: Option<&str>,
        token: Option<&str>,
    ) -> Request {
        let remote = peer.is_some_and(|ip| ip != [127, 0, 0, 1]);
        let host = if remote {
            "100.64.0.1:7681"
        } else {
            "127.0.0.1:7681"
        };
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header(header::HOST, host);
        if let Some(origin) = origin {
            req = req.header(header::ORIGIN, origin);
        }
        if let Some(token) = token {
            req = req.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        match peer {
            Some([127, 0, 0, 1]) => req = req.extension(loopback_peer()),
            Some(ip) => req = req.extension(ConnectInfo(SocketAddr::from((ip, 50000)))),
            None => {}
        }
        req.body(Body::empty()).unwrap()
    }

    async fn send(
        st: &AppState,
        method: Method,
        path: &str,
        peer: Option<[u8; 4]>,
        origin: Option<&str>,
        token: Option<&str>,
    ) -> StatusCode {
        crate::state::router(st.clone())
            .oneshot(request(method, path, peer, origin, token))
            .await
            .unwrap()
            .status()
    }

    #[tokio::test]
    async fn remote_peers_are_refused() {
        let st = test_state();
        for path in ["/", "/api/sessions", "/api/about"] {
            assert_eq!(
                send(&st, Method::GET, path, REMOTE, None, Some("t0k3n")).await,
                StatusCode::FORBIDDEN,
                "{path}"
            );
        }
    }

    #[tokio::test]
    async fn a_mapped_loopback_peer_is_loopback() {
        let st = test_state();
        let mapped = SocketAddr::from(([0, 0, 0, 0, 0, 0xffff, 0x7f00, 1], 50000));
        let req = Request::builder()
            .uri("/api/sessions")
            .header(header::HOST, "127.0.0.1:7681")
            .header(header::AUTHORIZATION, format!("Bearer {}", st.token))
            .extension(ConnectInfo(mapped))
            .body(Body::empty())
            .unwrap();
        let res = crate::state::router(st).oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn missing_peer_is_refused() {
        let st = test_state();
        assert_eq!(
            send(&st, Method::GET, "/api/sessions", None, None, Some("t0k3n")).await,
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn handlers_see_the_credential() {
        let st = test_state();
        let app = Router::new()
            .route(
                "/api/who",
                get(|who: Option<Extension<Credential>>| async move {
                    format!("{:?}", who.map(|Extension(c)| c))
                }),
            )
            .layer(axum::middleware::from_fn_with_state(st.clone(), guard))
            .with_state(st);
        let who = |peer, token| {
            let app = app.clone();
            async move {
                let res = app
                    .oneshot(request(Method::GET, "/api/who", peer, None, token))
                    .await
                    .unwrap();
                let body = axum::body::to_bytes(res.into_body(), usize::MAX)
                    .await
                    .unwrap();
                String::from_utf8(body.to_vec()).unwrap()
            }
        };
        assert_eq!(who(LOOPBACK, Some("t0k3n")).await, "Some(Main)");
        assert_eq!(who(LOOPBACK, None).await, "");
        assert_eq!(who(REMOTE, Some("t0k3n")).await, "");
    }

    #[test]
    fn host_must_be_local_or_an_address() {
        let host = |h: &str| {
            let mut headers = HeaderMap::new();
            headers.insert(header::HOST, HeaderValue::from_str(h).unwrap());
            host_is_address(&headers)
        };
        for ok in [
            "localhost:7681",
            "tabsh.localhost:7681",
            "127.0.0.1:7681",
            "[::1]:7681",
        ] {
            assert!(host(ok), "{ok}");
        }
        for bad in ["evil.example:7681", "evil.localhost:7681"] {
            assert!(!host(bad), "{bad}");
        }
    }

    #[tokio::test]
    async fn a_session_token_may_only_patch_its_own_status() {
        let st = test_state();
        let id = crate::sessions::store::insert_session(&st.db.lock().unwrap(), None)
            .unwrap()
            .id;
        let token = crate::sessions::store::ensure_session_token(&st.db.lock().unwrap(), &id)
            .unwrap();
        let app = crate::state::router(st.clone());

        let status = Request::builder()
            .method(Method::PATCH)
            .uri(format!("/api/sessions/{id}/status"))
            .header(header::HOST, "127.0.0.1:7681")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json")
            .extension(loopback_peer())
            .body(Body::from(r#"{"status":"completed","note":"ok"}"#))
            .unwrap();
        let res = app.clone().oneshot(status).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK, "own status is allowed");

        let create = Request::builder()
            .method(Method::POST)
            .uri("/api/sessions")
            .header(header::HOST, "127.0.0.1:7681")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json")
            .extension(loopback_peer())
            .body(Body::from("{}"))
            .unwrap();
        let res = app.clone().oneshot(create).await.unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN, "create needs the pairing token");

        let settings = Request::builder()
            .method(Method::GET)
            .uri("/api/settings")
            .header(header::HOST, "127.0.0.1:7681")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .extension(loopback_peer())
            .body(Body::empty())
            .unwrap();
        let res = app.clone().oneshot(settings).await.unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN);

        let other = Request::builder()
            .method(Method::PATCH)
            .uri("/api/sessions/not-this-card/status")
            .header(header::HOST, "127.0.0.1:7681")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json")
            .extension(loopback_peer())
            .body(Body::from(r#"{"status":"completed"}"#))
            .unwrap();
        let res = app.oneshot(other).await.unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN, "another card's status is refused");
    }

    #[test]
    fn privileged_routes_need_the_token_without_origin() {
        for path in [
            "/api/sessions",
            "/api/settings",
            "/api/uploads",
            "/api/about",
            "/api/board/events",
            "/ws",
            "/api/files/tree",
        ] {
            assert!(!admits_without_origin(&Method::GET, path, None), "{path}");
            assert!(
                admits_without_origin(&Method::GET, path, Some(&Credential::Main)),
                "{path}"
            );
        }
        for path in ["/", "/open"] {
            assert!(admits_without_origin(&Method::GET, path, None), "{path}");
            assert!(!admits_without_origin(&Method::POST, path, None), "{path}");
        }
    }

    #[tokio::test]
    async fn loopback_without_origin_or_token_is_refused() {
        let st = test_state();
        for (m, p) in [
            (Method::GET, "/api/sessions"),
            (Method::GET, "/api/about"),
            (Method::GET, "/ws?id=x"),
        ] {
            assert_eq!(
                send(&st, m.clone(), p, LOOPBACK, None, None).await,
                StatusCode::UNAUTHORIZED,
                "{m} {p}"
            );
            assert_ne!(
                send(&st, m.clone(), p, LOOPBACK, None, Some("t0k3n")).await,
                StatusCode::UNAUTHORIZED,
                "{m} {p} with token"
            );
        }
        assert_eq!(
            send(&st, Method::GET, "/", LOOPBACK, None, None).await,
            StatusCode::OK
        );
    }

    #[test]
    fn the_page_is_exactly_its_paths() {
        for path in ["/", "/open"] {
            assert!(is_page(&Method::GET, path), "{path}");
            assert!(!is_page(&Method::POST, path), "{path}");
        }
        for path in ["/app", "/ws", "/api/about"] {
            assert!(!is_page(&Method::GET, path), "{path}");
        }
    }
}
