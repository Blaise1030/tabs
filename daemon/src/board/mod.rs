//! The kanban board: every session is a card with a status, set by the
//! coding agent's hooks (through `tabsh status`) and by dragging cards on the board.

mod events;
pub(crate) mod rules;

use crate::{
    AppState,
    error::internal_error,
    sessions::{SessionInfo, store},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{get, patch},
};
use rules::Source;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

/// The agent a new card starts when the page names none.
pub(crate) const DEFAULT_COMMAND: &str = "claude {prompt}";

/// The short line typed into a new card's shell to start its agent. The
/// prompt itself travels in the shell's environment as `TABSH_PROMPT` (a PTY
/// in canonical mode cuts a typed line at 1024 bytes on macOS), so `command`
/// (the agent's launch template) gets `"$TABSH_PROMPT"` where `{prompt}` is,
/// or appended when it has none. That double-quoted expansion is one literal
/// argument in POSIX shells and fish alike. All on one line (a newline would
/// submit early) and free of control characters (which the PTY would take as
/// keystrokes), then Enter.
pub(crate) fn launch_line(command: &str) -> String {
    let command = one_line(command);
    let command = if command.is_empty() {
        DEFAULT_COMMAND.to_owned()
    } else {
        command
    };
    let line = if command.contains("{prompt}") {
        command.replace("{prompt}", PROMPT_ARG)
    } else {
        format!("{command} {PROMPT_ARG}")
    };
    format!("{line}\r")
}

const PROMPT_ARG: &str = "\"$TABSH_PROMPT\"";

/// A first prompt as stored: no NUL bytes, trimmed, and `None` when blank.
pub(crate) fn clean_prompt(raw: &str) -> Option<String> {
    let p = raw.replace('\0', "");
    let p = p.trim();
    (!p.is_empty()).then(|| p.to_owned())
}

/// A card's title made from its prompt: the first line with text, its
/// whitespace collapsed and control characters dropped, cut at
/// `PROMPT_TITLE_CHARS` with an ellipsis. `None` when nothing is left.
pub(crate) fn prompt_title(prompt: &str) -> Option<String> {
    let line = prompt.lines().map(one_line).find(|l| !l.is_empty())?;
    if line.chars().count() <= PROMPT_TITLE_CHARS {
        return Some(line);
    }
    let cut: String = line.chars().take(PROMPT_TITLE_CHARS - 1).collect();
    Some(format!("{}…", cut.trim_end()))
}

const PROMPT_TITLE_CHARS: usize = 200;

/// A command as one line of plain words: whitespace runs (newlines too)
/// become one space and control characters are dropped.
pub(crate) fn one_line(command: &str) -> String {
    command
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .filter(|c| !c.is_control())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// A new agent conversation's id, for a startup command with `{session}`:
/// a random UUID (v4), which Claude Code's `--session-id` takes too.
pub(crate) fn mint_session() -> String {
    use std::io::Read;
    let mut b = [0u8; 16];
    let random = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b));
    if random.is_err() {
        // Not expected on the Unix hosts tabsh runs on; the clock still
        // tells cards apart.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        b = nanos.to_le_bytes();
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

/// Whether a conversation id is a plain token, safe to type into a shell.
fn plain_session(s: &str) -> bool {
    (1..=128).contains(&s.len())
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// How a card made without a provider's resume command resumes a Claude
/// Code agent run in it by hand.
const CLAUDE_RESUME: &str = "claude --resume {session}";

/// The line that reopens an agent's conversation in a fresh shell after tabsh
/// restarts, once the agent's hooks have reported in. `template` is the
/// card's resume command (its provider's), whose `{session}` becomes the
/// conversation id the hook named; without one, an agent known by `agent`
/// gets its usual command. `None` when nothing fits, and whenever `{session}`
/// is wanted but the id isn't a plain token: the line is typed into a shell.
pub(crate) fn resume_line(
    template: Option<&str>,
    agent: Option<&str>,
    session: Option<&str>,
) -> Option<String> {
    let template = match template.filter(|t| !t.is_empty()) {
        Some(t) => t,
        None if agent == Some("claude") => CLAUDE_RESUME,
        None => return None,
    };
    if !template.contains("{session}") {
        return Some(format!("{template}\r"));
    }
    let session = session.filter(|s| plain_session(s))?;
    Some(format!("{}\r", template.replace("{session}", session)))
}

/// What `/api/board/events` sends every open page.
#[derive(Serialize, Clone, Debug)]
#[serde(untagged)]
pub(crate) enum BoardEvent {
    Status(StatusEvent),
    Activity(ActivityEvent),
    /// A card was made (from a page, or by `tabsh new`, which no page asked
    /// for): a page without it adds it where it is, and reorders nothing.
    Created {
        created: crate::sessions::SessionInfo,
    },
}

/// A session printed (throttled) or rang its bell: pages mark a parked tab,
/// which has no socket of its own to hear it.
#[derive(Serialize, Clone, Debug)]
pub(crate) struct ActivityEvent {
    /// Not `id`: pages older than this event look cards up by `id`, and
    /// would read one without a status as a move to Backlog.
    pub(crate) session: String,
    pub(crate) activity: crate::sessions::Activity,
    /// How long ago the output it reports came (a trailing signal reports
    /// output held back by the throttle): output from before a tab parked
    /// was already on its screen.
    pub(crate) age_ms: u64,
    /// The title the shell set since the last signal, if it changed: a
    /// parked tab has no xterm to read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) title: Option<String>,
}

/// A card's status changed; sent to every open page.
#[derive(Serialize, Clone, Debug)]
pub(crate) struct StatusEvent {
    pub(crate) id: String,
    pub(crate) status: String,
    pub(crate) status_at: i64,
    pub(crate) note: Option<String>,
    /// Who changed it: "user" (the board) or "hook" (the agent, through
    /// `tabsh status`). Pages notify only for a hook's change.
    pub(crate) source: &'static str,
}

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/sessions/{id}/status", patch(set_status))
        .route("/api/sessions/{id}/prompt", patch(set_prompt))
        .route(
            "/api/board/agents/{session}/status",
            patch(set_agent_status),
        )
        .route("/api/board/events", get(events::events))
}

#[derive(Deserialize)]
struct SetStatus {
    status: String,
    note: Option<String>,
    source: Option<String>,
    unless: Option<String>,
    /// The agent the hook runs under and its conversation, so a restart can
    /// resume it.
    agent: Option<String>,
    agent_session: Option<String>,
}

const NOTE_CHARS: usize = 200;

async fn set_status(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<SetStatus>,
) -> Result<Json<SessionInfo>, StatusCode> {
    apply_status_blocking(st, id, body, true).await
}

/// A hook that can't tell which terminal it runs in (an OpenCode plugin runs
/// in OpenCode's server) names its conversation instead: the card whose
/// agent has it, either exactly or, for a conversation tabsh named, with the
/// agent's own prefix in front (`ses_<id>`).
async fn set_agent_status(
    State(st): State<AppState>,
    Path(session): Path<String>,
    Json(body): Json<SetStatus>,
) -> Result<Json<SessionInfo>, StatusCode> {
    if !plain_session(&session) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let id: Option<String> = st
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT id FROM sessions
             WHERE parent IS NULL
               AND (agent_session = ?1
                OR (length(agent_session) = 36 AND substr(?1, -36) = agent_session))
             ORDER BY position LIMIT 1",
            params![session],
            |r| r.get(0),
        )
        .optional()
        .map_err(internal_error)?;
    let id = id.ok_or(StatusCode::NOT_FOUND)?;
    // The card already knows this conversation.
    apply_status_blocking(st, id, body, false).await
}

/// [`apply_status`] on the blocking pool: a move to In progress starts the
/// card's shell, and the worker moves on meanwhile.
async fn apply_status_blocking(
    st: AppState,
    id: String,
    body: SetStatus,
    record_agent: bool,
) -> Result<Json<SessionInfo>, StatusCode> {
    tokio::task::spawn_blocking(move || apply_status(&st, &id, body, record_agent))
        .await
        .map_err(internal_error)?
}

/// Sets card `id`'s status. With `record_agent`, a hook that names its agent
/// and conversation also makes the card resumable with them.
fn apply_status(
    st: &AppState,
    id: &str,
    body: SetStatus,
    record_agent: bool,
) -> Result<Json<SessionInfo>, StatusCode> {
    if !STATUSES.contains(&body.status.as_str()) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let source = if body.source.as_deref() == Some("user") {
        Source::User
    } else {
        Source::Hook
    };
    let note: Option<String> = body
        .note
        .map(|n| n.trim().chars().take(NOTE_CHARS).collect::<String>())
        .filter(|n| !n.is_empty());
    let mut db = st.db.lock().unwrap();
    let row: Option<(String, Option<String>, Option<String>, String)> = db
        .query_row(
            "SELECT status, resume_command, parent, mode FROM sessions WHERE id = ?1",
            params![id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get(3)?,
                ))
            },
        )
        .optional()
        .map_err(internal_error)?;
    let Some((current, template, parent, mode)) = row else {
        return Err(StatusCode::NOT_FOUND);
    };
    // A hook in a side shell changes nothing: the card's agent drives status.
    if parent.is_some() {
        return Err(StatusCode::CONFLICT);
    }
    // A hook means an agent is running in the card: a restart resumes it.
    let resume = (record_agent && source == Source::Hook)
        .then(|| {
            resume_line(
                template.as_deref(),
                body.agent.as_deref(),
                body.agent_session.as_deref(),
            )
        })
        .flatten();
    if let Some(line) = resume {
        let session = body.agent_session.as_deref().filter(|s| plain_session(s));
        db.execute(
            "UPDATE sessions SET resume_input = ?1, agent_session = COALESCE(?2, agent_session)
             WHERE id = ?3",
            params![line, session, id],
        )
        .map_err(internal_error)?;
    }
    let apply = rules::applies(&current, source, body.unless.as_deref());
    if apply {
        db.execute(
            "UPDATE sessions SET note = ?2,
                 status_at = CASE WHEN status = ?1 THEN status_at ELSE unixepoch() END,
                 status = ?1
             WHERE id = ?3",
            params![body.status, note, id],
        )
        .map_err(internal_error)?;
    }
    // A hook's move puts the card last in its new column (pages do the same
    // on its event); one that leaves the status alone doesn't move it.
    if apply && source == Source::Hook && current != body.status {
        append_to_column(&mut db, id, &body.status).map_err(internal_error)?;
    }
    let info = store::info(&db, id)
        .map_err(internal_error)?
        .ok_or(StatusCode::NOT_FOUND)?;
    drop(db);
    if apply && rules::launches(&body.status, source) {
        // A UI card starts its ACP chat; it never gets a PTY launch line.
        if mode == "ui" {
            crate::chat::manager::launch_ui(st, id);
        } else {
            crate::sessions::launch(st, id);
        }
    }
    // Archive frees the PTY / ACP process; the card stays on the board.
    if apply && body.status == "archived" && current != "archived" {
        crate::sessions::stop_runtime(st, id);
    }
    if apply {
        let _ = st.events.send(BoardEvent::Status(StatusEvent {
            id: info.id.clone(),
            status: info.status.clone(),
            status_at: info.status_at,
            note: info.note.clone(),
            source: match source {
                Source::User => "user",
                Source::Hook => "hook",
            },
        }));
    }
    Ok(Json(info))
}

/// ACP filled in for a missing CLI hook. A card that is no longer
/// `in_progress` was moved by a hook or a drag; that stands.
pub(crate) fn note_acp_status(
    db: &std::sync::Mutex<Connection>,
    events: &tokio::sync::broadcast::Sender<BoardEvent>,
    id: &str,
    status: &str,
) {
    if status != "needs_input" && status != "completed" {
        return;
    }
    let mut db = db.lock().unwrap_or_else(|e| e.into_inner());
    let current: Option<String> = db
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1 AND parent IS NULL",
            params![id],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten();
    if current.as_deref() != Some("in_progress") {
        return;
    }
    let note: Option<&str> = if status == "needs_input" {
        Some("Agent finished its turn")
    } else {
        None
    };
    if db
        .execute(
            "UPDATE sessions SET note = ?2,
                 status_at = CASE WHEN status = ?1 THEN status_at ELSE unixepoch() END,
                 status = ?1
             WHERE id = ?3",
            params![status, note, id],
        )
        .is_err()
    {
        return;
    }
    if append_to_column(&mut db, id, status).is_err() {
        return;
    }
    let info = store::info(&db, id).ok().flatten();
    drop(db);
    if let Some(info) = info {
        let _ = events.send(BoardEvent::Status(StatusEvent {
            id: info.id,
            status: info.status,
            status_at: info.status_at,
            note: info.note,
            source: "hook",
        }));
    }
}

/// User sent a prompt on a UI card: mirror the TUI hook's
/// `tabsh status in_progress` so a follow-up leaves Needs input / Completed.
pub(crate) fn note_acp_prompt(
    db: &std::sync::Mutex<Connection>,
    events: &tokio::sync::broadcast::Sender<BoardEvent>,
    id: &str,
) {
    let mut db = db.lock().unwrap_or_else(|e| e.into_inner());
    let current: Option<String> = db
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1 AND parent IS NULL",
            params![id],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten();
    match current.as_deref() {
        Some("needs_input") | Some("completed") => {}
        _ => return,
    }
    if db
        .execute(
            "UPDATE sessions SET note = NULL,
                 status_at = CASE WHEN status = 'in_progress' THEN status_at ELSE unixepoch() END,
                 status = 'in_progress'
             WHERE id = ?1",
            params![id],
        )
        .is_err()
    {
        return;
    }
    if append_to_column(&mut db, id, "in_progress").is_err() {
        return;
    }
    let info = store::info(&db, id).ok().flatten();
    drop(db);
    if let Some(info) = info {
        let _ = events.send(BoardEvent::Status(StatusEvent {
            id: info.id,
            status: info.status,
            status_at: info.status_at,
            note: info.note,
            source: "hook",
        }));
    }
}

/// Puts card `id` right after the last other card in `status`'s column (at
/// the very end of the tab order when that column is empty), as the board's
/// `dropOrder` does with no card to go before.
fn append_to_column(db: &mut Connection, id: &str, status: &str) -> rusqlite::Result<()> {
    let rest: Vec<(String, String)> = db
        .prepare(
            "SELECT id, status FROM sessions WHERE id != ?1 AND parent IS NULL ORDER BY position",
        )?
        .query_map(params![id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    let at = rest
        .iter()
        .rposition(|(_, s)| s == status)
        .map_or(rest.len(), |i| i + 1);
    let mut ids: Vec<String> = rest.into_iter().map(|(id, _)| id).collect();
    ids.insert(at, id.to_owned());
    store::reorder(db, &ids)
}

/// Every status a card can have, in board order.
pub(crate) const STATUSES: [&str; 5] = [
    "backlog",
    "in_progress",
    "needs_input",
    "completed",
    "archived",
];

/// What `set_prompt` reads of a card: its status, the line its drag types,
/// that line's launch template, its agent's conversation, and whether its
/// name was chosen.
type BacklogCard = (
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    bool,
    Option<String>,
);

#[derive(Deserialize)]
struct SetPrompt {
    prompt: String,
    /// A provider picked again: its launch template, and how its
    /// conversation resumes. `None` keeps the card's agent.
    command: Option<String>,
    resume: Option<String>,
}

/// A Backlog card's first prompt: the card hasn't started its agent, so the
/// prompt — and the provider that runs it — can still change. The prompt
/// rides in the shell's environment from its start, so a running shell is
/// swapped for a fresh one that carries the new prompt.
async fn set_prompt(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<SetPrompt>,
) -> Result<Json<SessionInfo>, StatusCode> {
    // The restart waits out a start of the card's shell: on the blocking
    // pool, so the worker moves on meanwhile.
    tokio::task::spawn_blocking(move || edit_prompt(&st, &id, body))
        .await
        .map_err(internal_error)?
}

fn edit_prompt(st: &AppState, id: &str, body: SetPrompt) -> Result<Json<SessionInfo>, StatusCode> {
    let prompt = clean_prompt(&body.prompt);
    let command = body
        .command
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(str::to_owned);
    let db = st.db.lock().unwrap();
    let card: Option<BacklogCard> = db
        .query_row(
            "SELECT status, pending_input, pending_command, agent_session, pinned, parent
             FROM sessions WHERE id = ?1",
            params![id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            },
        )
        .optional()
        .map_err(internal_error)?;
    let Some((status, line, stored_command, agent_session, pinned, parent)) = card else {
        return Err(StatusCode::NOT_FOUND);
    };
    if parent.is_some() {
        return Err(StatusCode::CONFLICT);
    }
    // Any other column means the card already started: its agent has the
    // prompt. Backlog is also the one column a drag can still start it from.
    if status != "backlog" {
        return Err(StatusCode::CONFLICT);
    }
    // A card with a prompt is titled by it (`prompt_title`, as on creation)
    // until its terminal gives it a title; an unpinned title follows the edit.
    let name = match (&prompt, pinned) {
        (Some(p), false) => prompt_title(p),
        _ => None,
    };
    let updated = match (&prompt, &command) {
        // No prompt left: a plain backlog shell again.
        (None, _) => db.execute(
            "UPDATE sessions SET pending_input = NULL, pending_prompt = NULL, pending_command = NULL,
                 name = COALESCE(?2, name)
             WHERE id = ?1",
            params![id, name],
        ),
        // The card keeps its agent; a plain card gains the default one.
        (Some(_), None) => {
            let line = line.unwrap_or_else(|| launch_line(DEFAULT_COMMAND));
            let command = stored_command.unwrap_or_else(|| DEFAULT_COMMAND.to_owned());
            db.execute(
                "UPDATE sessions SET pending_input = ?2, pending_prompt = ?3, pending_command = ?4,
                     name = COALESCE(?5, name)
                 WHERE id = ?1",
                params![id, line, prompt, command, name],
            )
        }
        // A provider picked again: rebuild its launch line, and how its
        // conversation resumes, as New card does.
        (Some(_), Some(c)) => {
            // The conversation the card named stays named; `{session}` mints
            // one when the card has none.
            let session = c.contains("{session}").then(|| {
                agent_session
                    .clone()
                    .unwrap_or_else(mint_session)
            });
            let line = launch_line(c);
            let line = session
                .as_ref()
                .map(|s| line.replace("{session}", s))
                .unwrap_or(line);
            let resume = body
                .resume
                .as_deref()
                .map(one_line)
                .filter(|r| !r.is_empty());
            let resume_input = session
                .as_deref()
                .and_then(|s| resume_line(resume.as_deref(), None, Some(s)));
            db.execute(
                "UPDATE sessions SET pending_input = ?2, pending_prompt = ?3, pending_command = ?4,
                     resume_command = ?5, agent_session = COALESCE(?6, agent_session), resume_input = ?7,
                     name = COALESCE(?8, name)
                 WHERE id = ?1",
                params![id, line, prompt, c, resume, session, resume_input, name],
            )
        }
    };
    updated.map_err(internal_error)?;
    let info = store::info(&db, id)
        .map_err(internal_error)?
        .ok_or(StatusCode::NOT_FOUND)?;
    drop(db);
    // The old shell was spawned with the old prompt in its environment.
    crate::sessions::restart(st, id);
    Ok(Json(info))
}

/// Adds the card columns to a `sessions` table that lacks them. SQLite can't
/// add a column with a non-constant default, so `status_at` starts at 0 and
/// is set to now for those rows.
pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    let cols: Vec<String> = conn
        .prepare("SELECT name FROM pragma_table_info('sessions')")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    for (name, ddl) in [
        (
            "status",
            "ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'backlog'",
        ),
        (
            "status_at",
            "ALTER TABLE sessions ADD COLUMN status_at INTEGER NOT NULL DEFAULT 0",
        ),
        ("note", "ALTER TABLE sessions ADD COLUMN note TEXT"),
        (
            "pending_input",
            "ALTER TABLE sessions ADD COLUMN pending_input TEXT",
        ),
        (
            "pending_prompt",
            "ALTER TABLE sessions ADD COLUMN pending_prompt TEXT",
        ),
        (
            "pending_command",
            "ALTER TABLE sessions ADD COLUMN pending_command TEXT",
        ),
        (
            "pinned",
            "ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "resume_command",
            "ALTER TABLE sessions ADD COLUMN resume_command TEXT",
        ),
        (
            "resume_input",
            "ALTER TABLE sessions ADD COLUMN resume_input TEXT",
        ),
        (
            "agent_session",
            "ALTER TABLE sessions ADD COLUMN agent_session TEXT",
        ),
        ("parent", "ALTER TABLE sessions ADD COLUMN parent TEXT"),
        (
            "mode",
            "ALTER TABLE sessions ADD COLUMN mode TEXT NOT NULL DEFAULT 'tui'",
        ),
        (
            "acp_command",
            "ALTER TABLE sessions ADD COLUMN acp_command TEXT",
        ),
        (
            "session_token",
            "ALTER TABLE sessions ADD COLUMN session_token TEXT",
        ),
    ] {
        if !cols.iter().any(|c| c == name) {
            conn.execute(ddl, [])?;
        }
    }
    conn.execute(
        "UPDATE sessions SET status_at = unixepoch() WHERE status_at = 0",
        [],
    )?;
    // One token per card: shells and ACP children present it instead of the
    // pairing token. Unique when set; several NULL rows are fine until mint.
    conn.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS sessions_session_token
         ON sessions(session_token) WHERE session_token IS NOT NULL",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{sessions::store::insert_session, state::router, test_support::test_state};
    use axum::http::{Method, Request, StatusCode};
    use tower::ServiceExt;

    async fn patch(
        st: &AppState,
        id: &str,
        body: serde_json::Value,
    ) -> (StatusCode, serde_json::Value) {
        req(
            st,
            Method::PATCH,
            &format!("/api/sessions/{id}/status"),
            body,
        )
        .await
    }

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
        let res = router(st.clone()).oneshot(req).await.unwrap();
        let status = res.status();
        let bytes = axum::body::to_bytes(res.into_body(), 1 << 20)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null),
        )
    }

    fn new_card(st: &AppState) -> String {
        insert_session(&st.db.lock().unwrap(), None).unwrap().id
    }

    fn order(st: &AppState) -> Vec<String> {
        st.db
            .lock()
            .unwrap()
            .prepare("SELECT id FROM sessions WHERE parent IS NULL ORDER BY position")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[tokio::test]
    async fn a_hook_appends_the_card_to_its_new_column_but_a_drag_does_not() {
        let st = test_state();
        let [a, b, c, d] = [0; 4].map(|_| new_card(&st));
        for id in [&a, &c] {
            patch(
                &st,
                id,
                serde_json::json!({"status": "in_progress", "source": "user"}),
            )
            .await;
        }
        assert_eq!(
            order(&st),
            [a.clone(), b.clone(), c.clone(), d.clone()],
            "a drag leaves the order to the board"
        );

        patch(&st, &d, serde_json::json!({"status": "in_progress"})).await;
        assert_eq!(
            order(&st),
            [a.clone(), b.clone(), c.clone(), d.clone()],
            "already after the column's last card"
        );
        patch(&st, &a, serde_json::json!({"status": "needs_input"})).await;
        assert_eq!(
            order(&st),
            [b.clone(), c.clone(), d.clone(), a.clone()],
            "an empty column: the very end"
        );
        patch(&st, &b, serde_json::json!({"status": "in_progress"})).await;
        assert_eq!(order(&st), [c.clone(), d.clone(), b.clone(), a.clone()]);

        patch(
            &st,
            &c,
            serde_json::json!({"status": "in_progress", "note": "x"}),
        )
        .await;
        assert_eq!(order(&st), [c, d, b, a], "same status: stays put");
    }

    #[tokio::test]
    async fn a_side_terminal_stays_out_of_the_board_order() {
        let st = test_state();
        let card = new_card(&st);
        let side = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                parent: Some(&card),
                ..Default::default()
            },
        )
        .unwrap();
        patch(&st, &card, serde_json::json!({"status": "in_progress"})).await;
        assert_eq!(order(&st), [card]);
        assert!(crate::sessions::exists(&st, &side.id));
    }

    // A drag to In progress starts the card's shell (no tab need be
    // attached) on the blocking pool: the worker that took the request (here,
    // the only one) moves on while it waits on the database or on `openpty`.
    #[test]
    fn a_launching_move_starts_its_shell_off_the_async_workers() {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                pending: Some("true\r"),
                prompt: Some("go"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        let (free, code) = {
            let (st2, id) = (st.clone(), id.clone());
            crate::test_support::off_the_worker(&st, async move {
                patch(
                    &st2,
                    &id,
                    serde_json::json!({"status": "in_progress", "source": "user"}),
                )
                .await
                .0
            })
        };
        assert_eq!(code, StatusCode::OK);
        assert!(
            st.live.lock().unwrap().contains_key(&id),
            "the drag started the shell"
        );
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(req(
                &st,
                Method::DELETE,
                &format!("/api/sessions/{id}"),
                serde_json::Value::Null,
            ));
        assert!(free, "the worker was free while the shell started");
    }

    // Archiving a live card kills its shell but keeps the row, so Archived
    // frees the process without losing the card.
    #[tokio::test]
    async fn archiving_stops_the_shell_and_keeps_the_card() {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                pending: Some("true\r"),
                prompt: Some("go"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        patch(
            &st,
            &id,
            serde_json::json!({"status": "in_progress", "source": "user"}),
        )
        .await;
        assert!(
            st.live.lock().unwrap().contains_key(&id),
            "the drag started the shell"
        );

        let (_, body) = patch(
            &st,
            &id,
            serde_json::json!({"status": "archived", "source": "user"}),
        )
        .await;
        assert_eq!(body["status"], "archived");
        assert!(crate::sessions::exists(&st, &id), "the card stays archived");

        let gone = {
            let st = st.clone();
            let id = id.clone();
            std::thread::spawn(move || {
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
                while st.live.lock().unwrap().contains_key(&id) {
                    if std::time::Instant::now() > deadline {
                        return false;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                true
            })
            .join()
            .unwrap()
        };
        assert!(gone, "the shell was killed");
        assert!(crate::sessions::exists(&st, &id), "killing did not delete it");
        assert!(!st.chats.pty_claimed(&id), "the PTY claim was released");
    }

    // Editing a Backlog card's prompt restarts its shell, which waits out a
    // start of that shell: on the blocking pool, so the worker moves on.
    #[test]
    fn a_prompt_edit_waits_off_the_async_workers() {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                pending: Some("true\r"),
                prompt: Some("go"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        let (free, code) = {
            let st2 = st.clone();
            crate::test_support::off_the_worker(&st, async move {
                req(
                    &st2,
                    Method::PATCH,
                    &format!("/api/sessions/{id}/prompt"),
                    serde_json::json!({"prompt": "go again"}),
                )
                .await
                .0
            })
        };
        assert_eq!(code, StatusCode::OK);
        assert!(free, "the worker was free while the edit waited");
    }

    #[test]
    fn events_on_the_stream_keep_their_shapes() {
        let status = BoardEvent::Status(StatusEvent {
            id: "a".into(),
            status: "completed".into(),
            status_at: 7,
            note: None,
            source: "hook",
        });
        assert_eq!(
            serde_json::to_value(&status).unwrap(),
            serde_json::json!({"id": "a", "status": "completed", "status_at": 7, "note": null, "source": "hook"}),
            "a status change is sent as before"
        );
        let bell = BoardEvent::Activity(ActivityEvent {
            session: "b".into(),
            activity: crate::sessions::Activity::Bell,
            age_ms: 0,
            title: None,
        });
        assert_eq!(
            serde_json::to_value(&bell).unwrap(),
            serde_json::json!({"session": "b", "activity": "bell", "age_ms": 0}),
            "no `id`: a page from before activity finds no card in it"
        );
        let titled = BoardEvent::Activity(ActivityEvent {
            session: "b".into(),
            activity: crate::sessions::Activity::Output,
            age_ms: 0,
            title: Some("✳ Claude Code".into()),
        });
        assert_eq!(
            serde_json::to_value(&titled).unwrap(),
            serde_json::json!({"session": "b", "activity": "output", "age_ms": 0, "title": "✳ Claude Code"}),
            "a title rides along only when there is one"
        );
    }

    /// The status change a test's patch sent.
    fn status_event(ev: BoardEvent) -> StatusEvent {
        match ev {
            BoardEvent::Status(ev) => ev,
            other => panic!("expected a status change, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_hook_moves_a_card_and_the_board_hears_it() {
        let st = test_state();
        let id = new_card(&st);
        let mut rx = st.events.subscribe();
        let (code, body) = patch(
            &st,
            &id,
            serde_json::json!({"status": "needs_input", "note": "  needs Bash  "}),
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(body["status"], "needs_input");
        assert_eq!(body["note"], "needs Bash");
        let ev = status_event(rx.try_recv().unwrap());
        assert_eq!(
            (ev.id.as_str(), ev.status.as_str(), ev.source),
            (id.as_str(), "needs_input", "hook")
        );
    }

    #[tokio::test]
    async fn the_board_hears_who_moved_a_card() {
        let st = test_state();
        let id = new_card(&st);
        let mut rx = st.events.subscribe();
        patch(
            &st,
            &id,
            serde_json::json!({"status": "completed", "source": "user"}),
        )
        .await;
        assert_eq!(status_event(rx.try_recv().unwrap()).source, "user");
    }

    #[tokio::test]
    async fn bad_status_is_400_and_unknown_session_is_404() {
        let st = test_state();
        let id = new_card(&st);
        assert_eq!(
            patch(&st, &id, serde_json::json!({"status": "doing"}))
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            patch(&st, "nope", serde_json::json!({"status": "backlog"}))
                .await
                .0,
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    async fn hooks_skip_archived_and_unless_but_the_board_does_not() {
        let st = test_state();
        let id = new_card(&st);
        patch(
            &st,
            &id,
            serde_json::json!({"status": "archived", "source": "user"}),
        )
        .await;
        let mut rx = st.events.subscribe();
        let (_, body) = patch(&st, &id, serde_json::json!({"status": "in_progress"})).await;
        assert_eq!(body["status"], "archived");
        assert!(rx.try_recv().is_err(), "no event when nothing changed");

        patch(
            &st,
            &id,
            serde_json::json!({"status": "completed", "source": "user"}),
        )
        .await;
        let (_, body) = patch(
            &st,
            &id,
            serde_json::json!({"status": "needs_input", "unless": "completed"}),
        )
        .await;
        assert_eq!(body["status"], "completed");
    }

    #[tokio::test]
    async fn status_at_only_moves_when_the_status_changes() {
        let st = test_state();
        let id = new_card(&st);
        st.db
            .lock()
            .unwrap()
            .execute("UPDATE sessions SET status_at = 5 WHERE id = ?1", [&id])
            .unwrap();
        let (_, body) = patch(
            &st,
            &id,
            serde_json::json!({"status": "backlog", "note": "x"}),
        )
        .await;
        assert_eq!(body["status_at"], 5);
        assert_eq!(body["note"], "x");
        let (_, body) = patch(&st, &id, serde_json::json!({"status": "in_progress"})).await;
        assert_ne!(body["status_at"], 5);
        assert_eq!(
            body["note"],
            serde_json::Value::Null,
            "a change without a note clears it"
        );
    }

    #[tokio::test]
    async fn a_backlog_card_can_change_its_first_prompt_and_its_agent() {
        let st = test_state();
        let typed = launch_line("gemini -i {prompt}");
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                prompt: Some("fix it"),
                pending: Some(typed.as_str()),
                command: Some("gemini -i {prompt}"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        let uri = format!("/api/sessions/{id}/prompt");

        // No command given: the card keeps its agent, and its unpinned title
        // follows the new prompt.
        let (code, body) = req(
            &st,
            Method::PATCH,
            &uri,
            serde_json::json!({"prompt": "  fix it again  "}),
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(body["pending_prompt"], "fix it again");
        assert_eq!(body["pending_command"], "gemini -i {prompt}");
        assert_eq!(body["name"], "fix it again", "titled by its prompt");
        let line: Option<String> = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                [&id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            line.as_deref(),
            Some("gemini -i \"$TABSH_PROMPT\"\r"),
            "the line the drag types is unchanged"
        );

        // A provider picked again rebuilds the line, and how its conversation
        // resumes, naming it when the card hasn't.
        let (_, body) = req(
            &st,
            Method::PATCH,
            &uri,
            serde_json::json!({
                "prompt": "go",
                "command": "claude {prompt} --session-id {session}",
                "resume": "claude --resume {session}"
            }),
        )
        .await;
        assert_eq!(
            body["pending_command"],
            "claude {prompt} --session-id {session}"
        );
        let (line, session, resume): (String, String, Option<String>) = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input, agent_session, resume_input FROM sessions WHERE id = ?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            line,
            format!("claude \"$TABSH_PROMPT\" --session-id {session}\r")
        );
        assert_eq!(session.len(), 36, "a conversation was minted");
        assert_eq!(
            resume.as_deref(),
            Some(format!("claude --resume {session}\r").as_str())
        );

        // A blank prompt clears all three: the card waits as a plain shell.
        let (_, body) = req(
            &st,
            Method::PATCH,
            &uri,
            serde_json::json!({"prompt": "   "}),
        )
        .await;
        assert_eq!(body["pending_prompt"], serde_json::Value::Null);
        assert_eq!(body["pending_command"], serde_json::Value::Null);
        let line: Option<String> = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                [&id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(line, None);

        // A plain card can gain a first prompt, on the default agent.
        let plain = new_card(&st);
        let (_, body) = req(
            &st,
            Method::PATCH,
            &format!("/api/sessions/{plain}/prompt"),
            serde_json::json!({"prompt": "hi"}),
        )
        .await;
        assert_eq!(body["pending_prompt"], "hi");
        assert_eq!(body["pending_command"], DEFAULT_COMMAND);
        let line: String = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                [&plain],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(line, "claude \"$TABSH_PROMPT\"\r");
    }

    #[tokio::test]
    async fn only_a_backlog_card_can_change_its_prompt() {
        let st = test_state();
        let id = new_card(&st);
        patch(
            &st,
            &id,
            serde_json::json!({"status": "in_progress", "source": "user"}),
        )
        .await;
        assert_eq!(
            req(
                &st,
                Method::PATCH,
                &format!("/api/sessions/{id}/prompt"),
                serde_json::json!({"prompt": "x"}),
            )
            .await
            .0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            req(
                &st,
                Method::PATCH,
                "/api/sessions/nope/prompt",
                serde_json::json!({"prompt": "x"}),
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }

    #[test]
    fn launch_line_is_short_and_reads_the_prompt_from_the_environment() {
        assert_eq!(launch_line(DEFAULT_COMMAND), "claude \"$TABSH_PROMPT\"\r");
        assert_eq!(
            launch_line("gemini -i {prompt}"),
            "gemini -i \"$TABSH_PROMPT\"\r"
        );
        assert_eq!(
            launch_line("codex"),
            "codex \"$TABSH_PROMPT\"\r",
            "appended when there's no {{prompt}}"
        );
        assert_eq!(
            launch_line("  "),
            "claude \"$TABSH_PROMPT\"\r",
            "blank means the default"
        );
        assert_eq!(
            launch_line("a {prompt} b {prompt}"),
            "a \"$TABSH_PROMPT\" b \"$TABSH_PROMPT\"\r"
        );
    }

    #[test]
    fn a_prompt_title_is_its_first_line_cut_short() {
        assert_eq!(
            prompt_title("\n  Fix the\tlogin   bug\nthen tests").as_deref(),
            Some("Fix the login bug")
        );
        assert_eq!(prompt_title(" \n\u{1b}\n").as_deref(), None);
        let long = prompt_title(&"word ".repeat(60)).unwrap();
        assert_eq!(long.chars().count(), 200);
        assert!(long.ends_with("word…"), "{long}");
    }

    #[test]
    fn launch_line_drops_control_characters_and_newlines() {
        assert_eq!(
            launch_line("claude\n--x {prompt}"),
            "claude --x \"$TABSH_PROMPT\"\r"
        );
        assert_eq!(
            launch_line("\u{1b}[A\u{3}claude\u{7f} {prompt}"),
            "[Aclaude \"$TABSH_PROMPT\"\r"
        );
    }

    #[test]
    fn resume_line_fills_in_plain_session_ids_only() {
        let codex = Some("codex resume {session}");
        assert_eq!(
            resume_line(codex, None, Some("3f1c-9a_B")).as_deref(),
            Some("codex resume 3f1c-9a_B\r")
        );
        assert_eq!(resume_line(codex, None, None), None);
        assert_eq!(resume_line(codex, None, Some("")), None);
        assert_eq!(resume_line(codex, None, Some("a; rm -rf ~")), None);
        assert_eq!(resume_line(codex, None, Some("a\rb")), None);
        assert_eq!(resume_line(codex, None, Some(&"a".repeat(129))), None);
        assert_eq!(
            resume_line(Some("codex resume --last"), None, None).as_deref(),
            Some("codex resume --last\r"),
            "a command without {{session}} needs no id"
        );
    }

    #[test]
    fn without_a_resume_command_only_claude_code_resumes() {
        assert_eq!(
            resume_line(None, Some("claude"), Some("s-1")).as_deref(),
            Some("claude --resume s-1\r")
        );
        assert_eq!(
            resume_line(Some(""), Some("claude"), Some("s-1")).as_deref(),
            Some("claude --resume s-1\r")
        );
        assert_eq!(resume_line(None, None, Some("s-1")), None);
        assert_eq!(resume_line(None, Some("vim"), Some("s-1")), None);
    }

    fn resume_input(st: &AppState, id: &str) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT resume_input FROM sessions WHERE id = ?1",
                [id],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[tokio::test]
    async fn a_hook_fills_in_the_cards_resume_command() {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                resume: Some("gemini --resume {session}"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        patch(
            &st,
            &id,
            serde_json::json!({"status": "in_progress", "source": "user"}),
        )
        .await;
        assert_eq!(resume_input(&st, &id), None, "a drag isn't the agent");
        patch(
            &st,
            &id,
            serde_json::json!({"status": "needs_input", "agent_session": "g-7"}),
        )
        .await;
        assert_eq!(
            resume_input(&st, &id).as_deref(),
            Some("gemini --resume g-7\r")
        );
    }

    #[tokio::test]
    async fn a_hook_that_names_its_conversation_makes_the_card_resumable() {
        let st = test_state();
        let id = new_card(&st);
        patch(&st, &id, serde_json::json!({"status": "in_progress"})).await;
        assert_eq!(resume_input(&st, &id), None);
        let (code, _) = patch(
            &st,
            &id,
            serde_json::json!({"status": "in_progress", "agent": "claude", "agent_session": "s-1"}),
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(
            resume_input(&st, &id).as_deref(),
            Some("claude --resume s-1\r")
        );
        patch(
            &st,
            &id,
            serde_json::json!({"status": "in_progress", "agent": "claude", "agent_session": "$(x)"}),
        )
        .await;
        assert_eq!(
            resume_input(&st, &id).as_deref(),
            Some("claude --resume s-1\r"),
            "an odd id is ignored, not stored"
        );
    }

    #[test]
    fn minted_sessions_are_random_v4_uuids() {
        let (a, b) = (mint_session(), mint_session());
        assert_ne!(a, b);
        assert_eq!(a.len(), 36);
        assert_eq!(&a[14..15], "4");
        assert!(plain_session(&a));
    }

    async fn patch_agent(st: &AppState, session: &str, body: serde_json::Value) -> StatusCode {
        let req = Request::builder()
            .method(Method::PATCH)
            .uri(format!("/api/board/agents/{session}/status"))
            .header("Host", "127.0.0.1:7681")
            .header("Authorization", "Bearer t0k3n")
            .header("Content-Type", "application/json")
            .extension(crate::test_support::loopback_peer())
            .body(axum::body::Body::from(body.to_string()))
            .unwrap();
        router(st.clone()).oneshot(req).await.unwrap().status()
    }

    fn status_of(st: &AppState, id: &str) -> String {
        st.db
            .lock()
            .unwrap()
            .query_row("SELECT status FROM sessions WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap()
    }

    #[tokio::test]
    async fn a_hook_finds_its_card_by_the_conversation_tabsh_named() {
        let st = test_state();
        let session = mint_session();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                agent_session: Some(&session),
                resume_input: Some("opencode --session ses_x\r"),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        let busy = serde_json::json!({"status": "in_progress"});
        // OpenCode puts its prefix in front of the id tabsh chose.
        assert_eq!(
            patch_agent(&st, &format!("ses_{session}"), busy.clone()).await,
            StatusCode::OK
        );
        assert_eq!(status_of(&st, &id), "in_progress");
        let done = serde_json::json!({"status": "needs_input", "agent_session": "ses_other"});
        assert_eq!(patch_agent(&st, &session, done).await, StatusCode::OK);
        assert_eq!(status_of(&st, &id), "needs_input");
        assert_eq!(
            resume_input(&st, &id).as_deref(),
            Some("opencode --session ses_x\r"),
            "the card keeps the conversation it named"
        );
        assert_eq!(
            patch_agent(&st, "ses_unknown", busy.clone()).await,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            patch_agent(&st, &session[1..], busy.clone()).await,
            StatusCode::NOT_FOUND,
            "a part of an id is not the id"
        );
        assert_eq!(
            patch_agent(&st, "a%3Bb", busy).await,
            StatusCode::BAD_REQUEST
        );
    }
}
