//! Shared by the feature modules' tests.

use crate::{AppState, auth, sessions::open_db};
use std::sync::{Arc, Mutex};

/// An in-memory daemon state with token `t0k3n`, accepting the hosted origin.
pub(crate) fn test_state() -> AppState {
    let db = open_db(":memory:").unwrap();
    let state = AppState {
        db: Arc::new(Mutex::new(db)),
        live: Default::default(),
        starting: Default::default(),
        db_path: ":memory:".into(),
        started: std::time::Instant::now(),
        token: "t0k3n".into(),
        origins: vec!["https://tabsh.cc".to_string()].into(),
        self_url: "http://127.0.0.1:7681".into(),
        events: tokio::sync::broadcast::channel(256).0,
        chats: crate::chat::ChatManager::from_db_path(":memory:"),
        port: 7681,
    };
    state
        .chats
        .bind_board(state.db.clone(), state.events.clone());
    state.chats.bind_url(&state.self_url);
    state
}

/// Serialises tests that edit process-global env vars.
pub(crate) static ENV: Mutex<()> = Mutex::new(());

/// The peer address of a request from this machine: the guard refuses
/// requests without one.
pub(crate) fn loopback_peer() -> axum::extract::ConnectInfo<std::net::SocketAddr> {
    axum::extract::ConnectInfo(std::net::SocketAddr::from(([127, 0, 0, 1], 50000)))
}

/// A fresh, empty directory under the system temp dir.
pub(crate) fn scratch() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("tabsh-test-{}", auth::random_hex(8).unwrap()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Holds `st.db` on another thread for `hold`, returning once it is held.
pub(crate) fn hold_db(
    st: &crate::AppState,
    hold: std::time::Duration,
) -> std::thread::JoinHandle<()> {
    let db = st.db.clone();
    let (held, is_held) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        let _db = db.lock().unwrap();
        held.send(()).unwrap();
        std::thread::sleep(hold);
    });
    is_held.recv().unwrap();
    holder
}

/// Runs `work` on a one-worker runtime while `st.db` is held, and says whether
/// the worker stayed free (work that blocks inline parks it).
pub(crate) fn off_the_worker<F>(st: &crate::AppState, work: F) -> (bool, F::Output)
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let rt = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    let holder = hold_db(st, std::time::Duration::from_millis(400));
    let out = rt.block_on(async {
        let t0 = std::time::Instant::now();
        let task = tokio::spawn(work);
        tokio::task::yield_now().await;
        let free = t0.elapsed() < std::time::Duration::from_millis(200);
        (free, task.await.unwrap())
    });
    holder.join().unwrap();
    out
}
