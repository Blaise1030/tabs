//! Explorer APIs Tabs uses: folder search, project tree, live watch.

mod folders;
mod resolve;
mod tree;
mod watch;

use crate::{AppState, error::internal_error};
use axum::{
    Json, Router,
    extract::{Query, State},
    response::{IntoResponse, Response},
    routing::get,
};
use folders::{FOLDER_LIMIT, matching_folders};
use resolve::session_base_dir;
use serde::Deserialize;
use std::path::PathBuf;
use tree::{TREE_LIMIT_PATHS, list_tree_or_folders, tree_root};

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/files/folders", get(file_folders))
        .route("/api/files/tree", get(file_tree))
        .route("/api/files/watch", get(watch::watch_handler))
}

#[derive(Deserialize)]
struct FoldersQuery {
    path: String,
}

#[derive(Deserialize)]
struct TreeQuery {
    session: Option<String>,
    path: Option<String>,
}

async fn file_tree(State(st): State<AppState>, Query(q): Query<TreeQuery>) -> Response {
    let cwd = session_base_dir(&st, q.session.as_deref().unwrap_or(""));
    let browse = q.path.filter(|p| PathBuf::from(p).is_absolute());
    let listed = tokio::task::spawn_blocking(move || {
        let root = match browse {
            Some(path) => PathBuf::from(path),
            None => tree_root(&cwd),
        };
        list_tree_or_folders(&root, TREE_LIMIT_PATHS)
    })
    .await;
    match listed {
        Ok(tree) => Json(tree).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn file_folders(Query(q): Query<FoldersQuery>) -> Response {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let found = {
        let home = PathBuf::from(&home);
        tokio::task::spawn_blocking(move || matching_folders(&home, &q.path, FOLDER_LIMIT)).await
    };
    match found {
        Ok(folders) => {
            Json(serde_json::json!({ "home": home, "folders": folders })).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        state::router,
        test_support::{loopback_peer, scratch, test_state},
    };
    use axum::body::to_bytes;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn tree_request(session: &str, auth: &[(&str, &str)]) -> Request<axum::body::Body> {
        let mut req = Request::builder()
            .uri(format!("/api/files/tree?session={session}"))
            .header("Host", "127.0.0.1:7681")
            .extension(loopback_peer());
        for (name, value) in auth {
            req = req.header(*name, *value);
        }
        req.body(axum::body::Body::empty()).unwrap()
    }

    #[tokio::test]
    async fn tree_lists_the_repo_root_of_a_known_session() {
        let dir = scratch();
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "").unwrap();
        let st = test_state();
        st.db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO sessions (id, name, position, cwd) VALUES ('s1', 'T', 1, ?1)",
                [dir.join("src").to_str().unwrap()],
            )
            .unwrap();
        let auth = [
            ("Origin", "https://tabsh.cc"),
            ("Authorization", "Bearer t0k3n"),
        ];
        let res = router(st).oneshot(tree_request("s1", &auth)).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["root"], dir.to_str().unwrap());
        assert_eq!(json["truncated"], false);
        let mut paths: Vec<&str> = json["paths"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap())
            .collect();
        paths.sort_unstable();
        assert_eq!(paths, ["src/", "src/main.rs"]);
    }

    #[tokio::test]
    async fn tree_of_an_unknown_session_falls_back_to_home() {
        let auth = [
            ("Origin", "https://tabsh.cc"),
            ("Authorization", "Bearer t0k3n"),
        ];
        let res = router(test_state())
            .oneshot(tree_request("nope", &auth))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(json["root"].is_string());
    }

    #[tokio::test]
    async fn folders_lists_the_subfolders_that_complete_a_path() {
        let dir = scratch();
        std::fs::create_dir_all(dir.join("code/tabsh")).unwrap();
        let req = Request::builder()
            .uri(format!("/api/files/folders?path={}/code/ta", dir.display()))
            .header("Host", "127.0.0.1:7681")
            .header("Origin", "https://tabsh.cc")
            .header("Authorization", "Bearer t0k3n")
            .extension(loopback_peer())
            .body(axum::body::Body::empty())
            .unwrap();
        let res = router(test_state()).oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            json["folders"],
            serde_json::json!([dir.join("code/tabsh").to_str().unwrap()])
        );
        assert_eq!(json["home"], std::env::var("HOME").unwrap());
    }

    #[tokio::test]
    async fn tree_needs_the_token_and_a_known_origin() {
        let res = router(test_state())
            .oneshot(tree_request("x", &[]))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
        let res = router(test_state())
            .oneshot(tree_request(
                "x",
                &[
                    ("Origin", "https://evil.example"),
                    ("Authorization", "Bearer t0k3n"),
                ],
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN);
    }
}
