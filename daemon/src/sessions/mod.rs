//! Shells that run in PTYs and outlive the browser tabs attached to them.

mod activity;
mod modes;
pub(crate) mod pty;
pub(crate) mod store;
mod ws;

use crate::{AppState, error::internal_error};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path, State},
    http::StatusCode,
    routing::{get, patch, put},
};
use modes::ModeTracker;
use portable_pty::{ChildKiller, MasterPty};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
#[cfg(test)]
use store::insert_session;
use tokio::sync::broadcast;

pub(crate) use activity::Activity;
pub(crate) use pty::SHUTTING_DOWN;
pub(crate) use store::{flush, open_db};

/// The tab list and the socket each tab attaches through.
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/sessions", get(list_sessions).post(create_session))
        .route("/api/sessions/order", put(reorder_sessions))
        .route(
            "/api/sessions/{id}",
            patch(rename_session).delete(delete_session),
        )
        .route("/ws", get(ws::ws_handler))
}

/// A session's working directory: its shell's live one, else the last one
/// saved.
pub(crate) fn cwd(st: &AppState, id: &str) -> Option<PathBuf> {
    let pid = st.live.lock().unwrap().get(id).and_then(|s| s.pid);
    pid.and_then(pty::process_cwd)
        .or_else(|| {
            st.db
                .lock()
                .unwrap()
                .query_row("SELECT cwd FROM sessions WHERE id = ?1", params![id], |r| {
                    r.get::<_, Option<String>>(0)
                })
                .optional()
                .ok()
                .flatten()
                .flatten()
        })
        .map(PathBuf::from)
}

/// Whether a session is still there: running, or saved.
pub(crate) fn exists(st: &AppState, id: &str) -> bool {
    st.live.lock().unwrap().contains_key(id)
        || st
            .db
            .lock()
            .unwrap()
            .query_row("SELECT 1 FROM sessions WHERE id = ?1", params![id], |_| {
                Ok(())
            })
            .optional()
            .is_ok_and(|row| row.is_some())
}

/// Starts a card's agent: types its pending launch line into its shell, once.
/// Spawns the shell if it isn't running yet, so a board drag (or New card in
/// In progress) can start the agent with no browser socket attached.
pub(crate) fn launch(st: &AppState, id: &str) {
    let Ok(Some(session)) = pty::get_or_spawn(st, id) else {
        return;
    };
    // A fresh spawn already typed via startup_input when pending was set; a
    // shell that was already live still needs the line (pending then clears).
    pty::type_launch_line(st, id, &session);
}

/// Replaces a card's shell with a fresh one. The first prompt rides in the
/// shell's environment from its start, so an edited prompt needs a new shell:
/// the old one is killed with its screen saved, and the next tab to attach
/// spawns the replacement (in the saved cwd, with the scrollback replayed).
pub(crate) fn restart(st: &AppState, id: &str) {
    let _turn = st.starting.turn(id);
    let Some(session) = st.live.lock().unwrap().remove(id) else {
        return;
    };
    // Flagged before the save, so a flush holding an older copy skips it.
    session.restarting.store(true, Ordering::SeqCst);
    let scrollback = session.output.lock().unwrap().scrollback_bytes();
    let cwd = session.pid.and_then(pty::process_cwd);
    if let Err(e) = st.db.lock().unwrap().execute(
        "UPDATE sessions SET scrollback = ?1, cwd = COALESCE(?2, cwd) WHERE id = ?3",
        params![scrollback, cwd, id],
    ) {
        eprintln!("failed to save session {id}: {e}");
    }
    let _ = session.killer.lock().unwrap().kill();
}

/// Running shells, by the name stored for the session and the shell's pid.
/// The daemon's performance page samples each of these, including the
/// processes the shell has started.
pub(crate) fn running_shells(st: &AppState) -> Vec<(String, u32)> {
    let live = st.live.lock().unwrap();
    let db = st.db.lock().unwrap();
    let mut rows = Vec::new();
    for (id, session) in live.iter() {
        let Some(pid) = session.pid else { continue };
        let name: String = db
            .query_row("SELECT name FROM sessions WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .unwrap_or_else(|_| id.clone());
        rows.push((name, pid));
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    rows
}

/// Running shells and all sessions, for the About dialog.
pub(crate) fn counts(st: &AppState) -> rusqlite::Result<(usize, i64)> {
    let running = st.live.lock().unwrap().len();
    let total = st.db.lock().unwrap().query_row(
        "SELECT COUNT(*) FROM sessions WHERE parent IS NULL",
        [],
        |r| r.get(0),
    )?;
    Ok((running, total))
}

/// Output kept per session so a reconnecting client can redraw its screen.
const SCROLLBACK_BYTES: usize = 512 * 1024;
/// How often changed scrollback and cwd are written to the database.
pub(crate) const FLUSH_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone, Debug)]
enum Event {
    Output(Bytes),
    /// A BEL outside an escape string, for attached pages.
    Bell,
    Exit,
    /// This shell was replaced (`restart`): the session stays; its tabs are
    /// told to reattach to the replacement.
    Restart,
}

/// A shell running in a PTY. It outlives any single WebSocket so a browser
/// reload can reattach; it ends when the shell exits or a client kills it.
pub(crate) struct Session {
    master: Mutex<Box<dyn MasterPty + Send>>,
    input: std::sync::mpsc::Sender<Bytes>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    pid: Option<u32>,
    /// Set before `restart` kills this shell: its end keeps the session (the
    /// replacement carries on) instead of deleting it.
    restarting: AtomicBool,
    /// Set before archive kills this shell: its end keeps the card row (no
    /// replacement) so Archived stays on the board without a live process.
    retaining: AtomicBool,
    // Scrollback and broadcast are updated under one lock so a new subscriber
    // sees every byte exactly once: replayed history, then live output.
    output: Mutex<Output>,
}

struct Output {
    scrollback: VecDeque<u8>,
    /// Terminal modes in effect where the scrollback starts, i.e. set by
    /// output that has since been trimmed off the front.
    trimmed_modes: ModeTracker,
    tx: broadcast::Sender<Event>,
    exited: bool,
    /// Scrollback changed since the last flush to the database.
    dirty: bool,
    /// Bytes this output has held, the restored scrollback included: where
    /// a page that kept its screen resumes from (`ws::attach`).
    total: u64,
    /// Names this count: each shell, in each daemon run, starts a new one.
    epoch: String,
}

#[derive(Serialize, Clone, Debug)]
pub(crate) struct SessionInfo {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) status: String,
    pub(crate) status_at: i64,
    pub(crate) note: Option<String>,
    pub(crate) cwd: Option<String>,
    /// A name the user chose: shell titles don't replace it.
    pub(crate) pinned: bool,
    /// The card's first prompt, while it waits in Backlog for its drag.
    pub(crate) pending_prompt: Option<String>,
    /// The launch template that prompt runs (its provider's), for an edit.
    pub(crate) pending_command: Option<String>,
    /// The agent it runs, by its launch template or else its resume command,
    /// so the board can show which one.
    pub(crate) agent_command: Option<String>,
    /// Set on a side terminal: the card it belongs to. Null on a card.
    pub(crate) parent: Option<String>,
    /// How the card runs: `"tui"` (a PTY shell) or `"ui"` (an ACP chat).
    pub(crate) mode: String,
    /// The provider's ACP command stored at create, for `"ui"` cards.
    pub(crate) acp_command: Option<String>,
}

#[derive(Deserialize)]
struct Rename {
    name: String,
    /// The name came from the shell's title, not the user: it doesn't pin.
    #[serde(default)]
    auto: bool,
}

#[derive(Deserialize)]
struct Order {
    ids: Vec<String>,
}

#[derive(Deserialize, Default)]
struct NewSession {
    cwd: Option<String>,
    name: Option<String>,
    prompt: Option<String>,
    command: Option<String>,
    /// The agent provider's resume command, `{session}` for the conversation.
    resume: Option<String>,
    /// The card this side terminal belongs to. One level only.
    parent: Option<String>,
    /// `"tui"` or `"ui"`; omitted means `"tui"`.
    mode: Option<String>,
    /// The provider's ACP command, for a `"ui"` card.
    acp_command: Option<String>,
}

async fn list_sessions(State(st): State<AppState>) -> Result<Json<Vec<SessionInfo>>, StatusCode> {
    let db = st.db.lock().unwrap();
    let mut stmt = db
        .prepare(&format!(
            "SELECT {} FROM sessions ORDER BY position",
            store::INFO_COLUMNS
        ))
        .map_err(internal_error)?;
    let rows = stmt
        .query_map([], store::info_row)
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(internal_error)?;
    Ok(Json(rows))
}

/// When `TABSH_TEST_ACP=1`, a UI card's stored ACP command is
/// `TABSH_CHAT_ACP` if that is non-empty, otherwise `fake-agent` on `PATH`.
/// The page can still send the provider's real command; end-to-end tests
/// never launch it.
fn ui_test_acp_override(mode: &str) -> Option<String> {
    if mode != "ui" || std::env::var("TABSH_TEST_ACP").ok().as_deref() != Some("1") {
        return None;
    }
    Some(
        std::env::var("TABSH_CHAT_ACP")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "fake-agent".to_string()),
    )
}

async fn create_session(
    State(st): State<AppState>,
    body: Option<Json<NewSession>>,
) -> Result<Json<SessionInfo>, StatusCode> {
    let body = body.map(|Json(b)| b).unwrap_or_default();
    let mode = match body.mode.as_deref() {
        None => "tui",
        Some(mode @ ("tui" | "ui")) => mode,
        Some(_) => return Err(StatusCode::BAD_REQUEST),
    };
    if let Some(parent) = body.parent.clone() {
        return create_side(&st, &parent, body);
    }
    if let Some(cwd_path) = body.cwd.as_deref()
        && !std::path::Path::new(cwd_path).is_dir()
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let name: Option<String> = body
        .name
        .map(|n| n.trim().chars().take(100).collect::<String>())
        .filter(|n| !n.is_empty());
    let prompt = body.prompt.as_deref().and_then(crate::board::clean_prompt);
    let command = body
        .command
        .as_deref()
        .unwrap_or(crate::board::DEFAULT_COMMAND);
    // `{session}` in the command: tabsh names the agent's conversation, so
    // it can be resumed (and its hooks found) without the agent saying so.
    let agent_session =
        (prompt.is_some() && command.contains("{session}")).then(crate::board::mint_session);
    let pending = prompt.as_ref().map(|_| {
        let line = crate::board::launch_line(command);
        match &agent_session {
            Some(s) => line.replace("{session}", s),
            None => line,
        }
    });
    // Without a name, a card is titled by its prompt; the title isn't
    // pinned, so the agent's terminal title can replace it.
    let pinned = name.is_some();
    let name = name.or_else(|| prompt.as_deref().and_then(crate::board::prompt_title));
    // Only a card that starts an agent has one to resume.
    let resume = prompt
        .as_ref()
        .and(body.resume.as_deref())
        .map(crate::board::one_line)
        .filter(|r| !r.is_empty());
    let resume_input = agent_session
        .as_deref()
        .and_then(|s| crate::board::resume_line(resume.as_deref(), None, Some(s)));
    // E2E sets `TABSH_TEST_ACP=1` so a UI card stores `fake-agent` (or
    // `TABSH_CHAT_ACP`) instead of the provider command the page sent.
    let test_acp = ui_test_acp_override(mode);
    let given_acp = body
        .acp_command
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty());
    let acp_command = test_acp.as_deref().or(given_acp);
    let card = store::NewCard {
        cwd: body.cwd.as_deref(),
        name: name.as_deref(),
        // Its agent starts when the card is dragged to In progress.
        status: "backlog",
        pending: pending.as_deref(),
        prompt: prompt.as_deref(),
        command: prompt.as_ref().map(|_| command.trim()),
        pinned,
        resume: resume.as_deref(),
        agent_session: agent_session.as_deref(),
        resume_input: resume_input.as_deref(),
        parent: None,
        mode,
        acp_command,
    };
    let card = store::insert_card(&st.db.lock().unwrap(), &card).map_err(internal_error)?;
    let _ = st.events.send(crate::board::BoardEvent::Created {
        created: card.clone(),
    });
    Ok(Json(card))
}

/// A side terminal of `parent`: a shell in that card's folder, named the
/// lowest free `Terminal N` among that card's side terminals. It is not a card.
fn create_side(
    st: &AppState,
    parent: &str,
    body: NewSession,
) -> Result<Json<SessionInfo>, StatusCode> {
    if body.prompt.is_some() || body.command.is_some() || body.resume.is_some() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let saved = {
        let db = st.db.lock().unwrap();
        db.query_row(
            "SELECT parent, cwd FROM sessions WHERE id = ?1",
            params![parent],
            |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                ))
            },
        )
        .optional()
        .map_err(internal_error)?
    };
    let Some((their_parent, saved_cwd)) = saved else {
        return Err(StatusCode::BAD_REQUEST);
    };
    if their_parent.is_some() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let cwd = match body.cwd {
        Some(cwd) => Some(cwd),
        None => cwd(st, parent)
            .map(|p| p.to_string_lossy().into_owned())
            .or(saved_cwd),
    };
    if let Some(cwd_path) = cwd.as_deref()
        && !std::path::Path::new(cwd_path).is_dir()
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let db = st.db.lock().unwrap();
    let name = store::next_side_name(&db, parent).map_err(internal_error)?;
    let card = store::NewCard {
        cwd: cwd.as_deref(),
        name: Some(&name),
        parent: Some(parent),
        pinned: false,
        ..Default::default()
    };
    store::insert_card(&db, &card)
        .map(Json)
        .map_err(internal_error)
}

async fn rename_session(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<Rename>,
) -> StatusCode {
    let name: String = body.name.trim().chars().take(100).collect();
    if name.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    match st.db.lock().unwrap().execute(
        "UPDATE sessions SET name = ?1, pinned = pinned OR ?2 WHERE id = ?3",
        params![name, !body.auto, id],
    ) {
        Ok(0) => StatusCode::NOT_FOUND,
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => internal_error(e),
    }
}

/// Puts the tabs in the order given (the tab strip after a drag). Ids that
/// aren't sessions are skipped; sessions left out keep their place after the
/// ones given.
async fn reorder_sessions(State(st): State<AppState>, Json(body): Json<Order>) -> StatusCode {
    let mut db = st.db.lock().unwrap();
    match store::reorder(&mut db, &body.ids) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(e) => internal_error(e),
    }
}

/// Close a tab. A running shell is killed and its reader thread removes the
/// row (and tells attached clients); a not-yet-restored one is just deleted.
async fn delete_session(State(st): State<AppState>, Path(id): Path<String>) -> StatusCode {
    // On the blocking pool: the close waits out a start of this tab's shell.
    tokio::task::spawn_blocking(move || close(&st, &id))
        .await
        .unwrap_or_else(internal_error)
}

/// Closes each side terminal of a card, through [`close`].
pub(crate) fn close_children(st: &AppState, parent: &str) {
    let ids: Vec<String> = st
        .db
        .lock()
        .unwrap()
        .prepare("SELECT id FROM sessions WHERE parent = ?1")
        .and_then(|mut stmt| {
            stmt.query_map(params![parent], |r| r.get(0))?
                .collect::<Result<Vec<_>, _>>()
        })
        .unwrap_or_default();
    for id in ids {
        let _ = close(st, &id);
    }
}

/// Stops a card's PTY and ACP agent without deleting the row. Archive uses
/// this so the card stays on the board while the process goes away.
pub(crate) fn stop_runtime(st: &AppState, id: &str) {
    st.chats.forget(id);
    if is_card(st, id) {
        close_children(st, id);
    }
    // Waits out a start of this tab's shell, so that shell is killed too.
    let _turn = st.starting.turn(id);
    let live = st.live.lock().unwrap();
    if let Some(session) = live.get(id) {
        // Reader releases the PTY claim and leaves the row (see retaining).
        session.retaining.store(true, Ordering::SeqCst);
        let _ = session.killer.lock().unwrap().kill();
        return;
    }
    drop(live);
    st.chats.release_pty(id);
}

/// The reader thread, once a shell has exited (not a restart): the row goes,
/// and a card takes its side terminals with it.
pub(crate) fn forget_exited(st: &AppState, id: &str) {
    let parent: Option<Option<String>> = st
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT parent FROM sessions WHERE id = ?1",
            params![id],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten();
    let Some(parent) = parent else {
        return;
    };
    if let Err(e) = st
        .db
        .lock()
        .unwrap()
        .execute("DELETE FROM sessions WHERE id = ?1", params![id])
    {
        eprintln!("failed to delete session {id}: {e}");
        return;
    }
    if parent.is_none() {
        close_children(st, id);
    }
}

fn is_card(st: &AppState, id: &str) -> bool {
    st.db
        .lock()
        .unwrap()
        .query_row(
            "SELECT parent FROM sessions WHERE id = ?1",
            params![id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .is_some_and(|parent| parent.is_none())
}

fn close(st: &AppState, id: &str) -> StatusCode {
    st.chats.forget(id);
    if is_card(st, id) {
        close_children(st, id);
    }
    // Waits out a start of this tab's shell, so that shell is killed too.
    let _turn = st.starting.turn(id);
    let live = st.live.lock().unwrap();
    if let Some(session) = live.get(id) {
        // Its reader thread releases the PTY surface claim as it exits.
        let _ = session.killer.lock().unwrap().kill();
        return StatusCode::NO_CONTENT;
    }
    drop(live);
    // No live shell (never started, already exited, or mid-restart):
    // no reader will release the PTY claim, so close releases it here.
    st.chats.release_pty(id);
    match st
        .db
        .lock()
        .unwrap()
        .execute("DELETE FROM sessions WHERE id = ?1", params![id])
    {
        Ok(0) => StatusCode::NOT_FOUND,
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => internal_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::test_state;

    // Closing a tab waits out a start of its shell: on the blocking pool, so
    // the worker that took the request moves on.
    #[test]
    fn closing_a_tab_waits_off_the_async_workers() {
        let st = test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let (free, code) = crate::test_support::off_the_worker(
            &st,
            delete_session(State(st.clone()), Path(id.clone())),
        );
        assert_eq!(code, StatusCode::NO_CONTENT);
        assert!(free, "the worker was free while the close waited");
        assert!(!exists(&st, &id));
    }

    #[test]
    fn cwd_falls_back_to_the_saved_column() {
        let st = test_state();
        let info = insert_session(&st.db.lock().unwrap(), Some("/tmp")).unwrap();
        assert_eq!(cwd(&st, &info.id), Some(PathBuf::from("/tmp")));
        assert_eq!(cwd(&st, "missing"), None);
    }

    use axum::http::{Method, Request};
    use tower::ServiceExt;

    async fn req(
        st: &AppState,
        method: Method,
        uri: &str,
        body: serde_json::Value,
    ) -> (StatusCode, serde_json::Value) {
        let req = Request::builder()
            .method(method)
            .uri(uri)
            .header("Host", "127.0.0.1:7681")
            .header("Authorization", "Bearer t0k3n")
            .header("Content-Type", "application/json")
            .extension(crate::test_support::loopback_peer())
            .body(axum::body::Body::from(body.to_string()))
            .unwrap();
        let res = crate::state::router(st.clone()).oneshot(req).await.unwrap();
        let code = res.status();
        let bytes = axum::body::to_bytes(res.into_body(), 1 << 20)
            .await
            .unwrap();
        (code, serde_json::from_slice(&bytes).unwrap_or_default())
    }

    async fn create(st: &AppState, body: serde_json::Value) -> (StatusCode, serde_json::Value) {
        req(st, Method::POST, "/api/sessions", body).await
    }

    fn pending(st: &AppState, id: &serde_json::Value) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                [id.as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn prompt(st: &AppState, id: &serde_json::Value) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_prompt FROM sessions WHERE id = ?1",
                [id.as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn command(st: &AppState, id: &serde_json::Value) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_command FROM sessions WHERE id = ?1",
                [id.as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[tokio::test]
    async fn a_card_with_a_prompt_waits_in_backlog_with_its_agent_pending() {
        let st = test_state();
        let (code, body) = create(
            &st,
            serde_json::json!({"cwd": "/tmp", "name": " Fix login ", "prompt": "fix it"}),
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(
            (body["name"].as_str(), body["status"].as_str()),
            (Some("Fix login"), Some("backlog"))
        );
        assert_eq!(
            pending(&st, &body["id"]).as_deref(),
            Some("claude \"$TABSH_PROMPT\"\r")
        );
        assert_eq!(prompt(&st, &body["id"]).as_deref(), Some("fix it"));
        assert_eq!(
            command(&st, &body["id"]).as_deref(),
            Some("claude {prompt}"),
            "the default agent is remembered for an edit"
        );
        let (_, body) = create(
            &st,
            serde_json::json!({"prompt": "hi", "command": "gemini -i {prompt}"}),
        )
        .await;
        assert_eq!(
            pending(&st, &body["id"]).as_deref(),
            Some("gemini -i \"$TABSH_PROMPT\"\r")
        );
        assert_eq!(
            command(&st, &body["id"]).as_deref(),
            Some("gemini -i {prompt}")
        );
    }

    #[tokio::test]
    async fn a_long_nasty_prompt_is_stored_verbatim_and_the_typed_line_stays_short() {
        let st = test_state();
        let nasty = "it's $(rm -rf ~) `x` \"q\"\nsecond line\n".repeat(150);
        assert!(nasty.len() > 5000);
        let (code, body) =
            create(&st, serde_json::json!({"prompt": format!("  {nasty}\0  ")})).await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(prompt(&st, &body["id"]).as_deref(), Some(nasty.trim()));
        let line = pending(&st, &body["id"]).unwrap();
        assert_eq!(line, "claude \"$TABSH_PROMPT\"\r");
        assert!(line.len() < 100);
    }

    #[tokio::test]
    async fn a_named_card_is_pinned_and_a_user_rename_pins() {
        let st = test_state();
        let (_, named) = create(&st, serde_json::json!({"name": "Fix login"})).await;
        assert_eq!(named["pinned"], true);
        let (_, plain) = create(&st, serde_json::json!({})).await;
        assert_eq!(plain["pinned"], false);
        let id = plain["id"].as_str().unwrap();
        let rename = |body: serde_json::Value| {
            let req = Request::builder()
                .method(Method::PATCH)
                .uri(format!("/api/sessions/{id}"))
                .header("Host", "127.0.0.1:7681")
                .header("Authorization", "Bearer t0k3n")
                .header("Content-Type", "application/json")
                .extension(crate::test_support::loopback_peer())
                .body(axum::body::Body::from(body.to_string()))
                .unwrap();
            crate::state::router(st.clone()).oneshot(req)
        };
        let pinned = || -> bool {
            st.db
                .lock()
                .unwrap()
                .query_row("SELECT pinned FROM sessions WHERE id = ?1", [id], |r| {
                    r.get(0)
                })
                .unwrap()
        };
        rename(serde_json::json!({"name": "~/code", "auto": true}))
            .await
            .unwrap();
        assert!(!pinned(), "a shell title does not pin");
        rename(serde_json::json!({"name": "Mine"})).await.unwrap();
        assert!(pinned());
    }

    fn resume_command(st: &AppState, id: &serde_json::Value) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT resume_command FROM sessions WHERE id = ?1",
                [id.as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[tokio::test]
    async fn a_card_keeps_its_providers_resume_command_on_one_line() {
        let st = test_state();
        let (_, body) = create(
            &st,
            serde_json::json!({"prompt": "go", "command": "codex {prompt}", "resume": " codex\n resume\u{7} {session} "}),
        )
        .await;
        assert_eq!(
            resume_command(&st, &body["id"]).as_deref(),
            Some("codex resume {session}")
        );
        let (_, body) = create(&st, serde_json::json!({"resume": "codex resume {session}"})).await;
        assert_eq!(
            resume_command(&st, &body["id"]),
            None,
            "no agent, no resume"
        );
        let (_, body) = create(&st, serde_json::json!({"prompt": "go", "resume": "  "})).await;
        assert_eq!(resume_command(&st, &body["id"]), None);
    }

    #[tokio::test]
    async fn a_card_without_a_name_is_titled_by_its_prompt_unpinned() {
        let st = test_state();
        let (_, body) = create(&st, serde_json::json!({"prompt": "Fix login\nmore"})).await;
        assert_eq!(body["name"], "Fix login");
        assert_eq!(body["pinned"], false);
    }

    fn column(st: &AppState, id: &serde_json::Value, col: &str) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                &format!("SELECT {col} FROM sessions WHERE id = ?1"),
                [id.as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[tokio::test]
    async fn a_session_in_the_command_is_named_by_tabsh_and_resumable_at_once() {
        let st = test_state();
        let (_, body) = create(
            &st,
            serde_json::json!({
                "prompt": "go",
                "command": "opencode --session ses_{session} --prompt {prompt}",
                "resume": "opencode --session ses_{session}",
            }),
        )
        .await;
        let session = column(&st, &body["id"], "agent_session").unwrap();
        assert_eq!(session.len(), 36);
        assert!(session.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
        assert_eq!(
            pending(&st, &body["id"]),
            Some(format!(
                "opencode --session ses_{session} --prompt \"$TABSH_PROMPT\"\r"
            ))
        );
        assert_eq!(
            column(&st, &body["id"], "resume_input"),
            Some(format!("opencode --session ses_{session}\r"))
        );
        let (_, other) = create(
            &st,
            serde_json::json!({"prompt": "go", "command": "x --session {session}"}),
        )
        .await;
        assert_ne!(column(&st, &other["id"], "agent_session"), Some(session));
        let (_, plain) = create(&st, serde_json::json!({"prompt": "go"})).await;
        assert_eq!(column(&st, &plain["id"], "agent_session"), None);
        assert_eq!(column(&st, &plain["id"], "resume_input"), None);
    }

    #[tokio::test]
    async fn a_card_without_a_prompt_is_a_backlog_shell() {
        let st = test_state();
        let (_, body) = create(&st, serde_json::json!({"name": "Docs", "prompt": "   "})).await;
        assert_eq!(body["status"], "backlog");
        assert_eq!(pending(&st, &body["id"]), None);
        let (_, body) = create(&st, serde_json::json!({})).await;
        assert_eq!(body["name"], "Terminal 1");
    }

    #[tokio::test]
    async fn a_new_card_is_announced_to_open_pages() {
        // `tabsh new` makes cards no page asked for: pages must hear of them.
        // The card itself, not a resync: re-reading the whole list would undo
        // the order a page just gave the card it made.
        let st = test_state();
        let mut rx = st.events.subscribe();
        let (code, card) = create(&st, serde_json::json!({"cwd": "/tmp", "prompt": "hi"})).await;
        assert_eq!(code, StatusCode::OK);
        let ev = serde_json::to_value(rx.try_recv().expect("an event")).unwrap();
        assert_eq!(ev, serde_json::json!({ "created": card }));
    }

    #[tokio::test]
    async fn create_session_accepts_mode_ui() {
        let st = test_state();
        let (code, body) = create(&st, serde_json::json!({"cwd": "/tmp", "mode": "ui"})).await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(body["mode"], "ui");
        assert_eq!(
            column(&st, &body["id"], "mode").as_deref(),
            Some("ui"),
            "the mode is stored on the session"
        );
        let (_, plain) = create(&st, serde_json::json!({"cwd": "/tmp"})).await;
        assert_eq!(plain["mode"], "tui", "an omitted mode defaults to tui");
        assert_eq!(column(&st, &plain["id"], "mode").as_deref(), Some("tui"));
    }

    #[tokio::test]
    async fn create_session_rejects_unknown_mode() {
        let st = test_state();
        let (code, _) = create(&st, serde_json::json!({"cwd": "/tmp", "mode": "bogus"})).await;
        assert_eq!(code, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn a_side_terminal_belongs_to_its_card_and_takes_the_lowest_free_name() {
        let st = test_state();
        let (_, card) = create(&st, serde_json::json!({"cwd": "/tmp"})).await;
        let parent = card["id"].as_str().unwrap();
        let (code, side) = create(&st, serde_json::json!({"parent": parent})).await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(side["parent"], parent);
        assert_eq!(side["name"], "Terminal 1");
        assert_eq!(side["cwd"], "/tmp");
        let (_, second) = create(&st, serde_json::json!({"parent": parent})).await;
        assert_eq!(second["name"], "Terminal 2");
        close(&st, second["id"].as_str().unwrap());
        let (_, again) = create(&st, serde_json::json!({"parent": parent})).await;
        assert_eq!(again["name"], "Terminal 2");
        close(&st, side["id"].as_str().unwrap());
        let (_, reused) = create(&st, serde_json::json!({"parent": parent})).await;
        assert_eq!(reused["name"], "Terminal 1");
    }

    #[tokio::test]
    async fn a_side_terminal_is_refused_without_a_card_or_with_an_agent() {
        let st = test_state();
        let (missing, _) = create(&st, serde_json::json!({"parent": "nope"})).await;
        assert_eq!(missing, StatusCode::BAD_REQUEST);
        let (_, card) = create(&st, serde_json::json!({})).await;
        let parent = card["id"].as_str().unwrap();
        let (_, side) = create(&st, serde_json::json!({"parent": parent})).await;
        let (nested, _) = create(&st, serde_json::json!({"parent": side["id"]})).await;
        assert_eq!(nested, StatusCode::BAD_REQUEST);
        for extra in [
            serde_json::json!({"parent": parent, "prompt": "go"}),
            serde_json::json!({"parent": parent, "command": "true"}),
            serde_json::json!({"parent": parent, "resume": "agent --resume={session}"}),
        ] {
            let (code, _) = create(&st, extra).await;
            assert_eq!(code, StatusCode::BAD_REQUEST);
        }
    }

    #[tokio::test]
    async fn the_session_list_carries_parent_and_counts_count_cards() {
        let st = test_state();
        let (_, card) = create(&st, serde_json::json!({})).await;
        let (_, side) = create(&st, serde_json::json!({"parent": card["id"]})).await;
        let list = list_sessions(State(st.clone())).await.unwrap().0;
        let side_row = list.iter().find(|s| s.id == side["id"]).unwrap();
        assert_eq!(
            side_row.parent.as_deref(),
            Some(card["id"].as_str().unwrap())
        );
        assert_eq!(
            list.iter().find(|s| s.id == card["id"]).unwrap().parent,
            None
        );
        assert_eq!(counts(&st).unwrap().1, 1);
    }

    #[tokio::test]
    async fn status_and_prompt_refuse_a_side_terminal() {
        let st = test_state();
        let (_, card) = create(&st, serde_json::json!({})).await;
        let (_, side) = create(&st, serde_json::json!({"parent": card["id"]})).await;
        let id = side["id"].as_str().unwrap();
        let (status, _) = req(
            &st,
            Method::PATCH,
            &format!("/api/sessions/{id}/status"),
            serde_json::json!({"status": "in_progress"}),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        let (prompt, _) = req(
            &st,
            Method::PATCH,
            &format!("/api/sessions/{id}/prompt"),
            serde_json::json!({"prompt": "go"}),
        )
        .await;
        assert_eq!(prompt, StatusCode::CONFLICT);
    }

    #[test]
    fn closing_a_card_closes_its_side_terminals_and_a_side_exit_leaves_the_card() {
        let st = test_state();
        let card = insert_session(&st.db.lock().unwrap(), Some("/tmp")).unwrap();
        let side = store::insert_card(
            &st.db.lock().unwrap(),
            &store::NewCard {
                parent: Some(&card.id),
                cwd: Some("/tmp"),
                ..Default::default()
            },
        )
        .unwrap();
        forget_exited(&st, &card.id);
        assert!(!exists(&st, &card.id));
        assert!(!exists(&st, &side.id));

        let card = insert_session(&st.db.lock().unwrap(), None).unwrap();
        let side = store::insert_card(
            &st.db.lock().unwrap(),
            &store::NewCard {
                parent: Some(&card.id),
                ..Default::default()
            },
        )
        .unwrap();
        forget_exited(&st, &side.id);
        assert!(exists(&st, &card.id));
        assert!(!exists(&st, &side.id));

        let card = insert_session(&st.db.lock().unwrap(), None).unwrap();
        let side = store::insert_card(
            &st.db.lock().unwrap(),
            &store::NewCard {
                parent: Some(&card.id),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(close(&st, &card.id), StatusCode::NO_CONTENT);
        assert!(!exists(&st, &card.id));
        assert!(!exists(&st, &side.id));
    }

    #[test]
    fn stop_runtime_kills_the_shell_and_keeps_the_card() {
        let st = test_state();
        let id = insert_session(&st.db.lock().unwrap(), Some("/tmp")).unwrap().id;
        let session = pty::get_or_spawn(&st, &id).unwrap().unwrap();
        assert!(st.live.lock().unwrap().contains_key(&id));

        st.db.lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET status = 'archived' WHERE id = ?1",
                params![id],
            )
            .unwrap();
        stop_runtime(&st, &id);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while st.live.lock().unwrap().contains_key(&id) {
            assert!(std::time::Instant::now() < deadline, "shell never left");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(exists(&st, &id), "the archived card stayed");
        assert!(!st.chats.pty_claimed(&id));
        // Keep the Arc alive until the reader has finished with it.
        drop(session);
    }
}
