//! Per-card ACP lifecycle: at most one live ACP agent per UI card.
//!
//! Starting a chat while that card's agent PTY is live is refused (409),
//! and the PTY start path refuses while a chat is live — see
//! `sessions::pty::get_or_spawn`. A UI card moved to In progress starts
//! here with its `pending_prompt` as the first ACP prompt; no PTY launch
//! line is ever typed for it.
//!
//! Mutual exclusion is one atomic claim, not two check-then-act
//! sequences: the chat entries and the PTY claims live behind the same
//! lock, so reserving either surface is a single locked step. A chat
//! claim is its map entry (`Starting` or `Live`); a PTY claim is an id
//! in `pty` from `try_claim_pty` until the shell's exit or close
//! releases it (`release_pty`). Whoever claims first wins — the loser
//! gets a conflict, never a second live surface.

use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use rusqlite::{OptionalExtension, params};
use tokio::sync::{broadcast, watch};

use super::{
    acp::{AcpClient, AcpEvent},
    models::{ConfigOptions, ModeConfig, ModelConfig},
    normalize::{UiChunk, to_chunks},
    transcript,
};
use crate::AppState;

#[derive(Debug)]
pub(crate) enum ChatError {
    Invalid(String),
    NotLive,
    /// The card's other agent surface (its PTY) holds the claim.
    Conflict(String),
    Failed(String),
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ChatError::Invalid(m) | ChatError::Conflict(m) | ChatError::Failed(m) => {
                write!(f, "{m}")
            }
            ChatError::NotLive => write!(f, "no live chat for this session"),
        }
    }
}

impl std::error::Error for ChatError {}

type ChatResult<T> = std::result::Result<T, ChatError>;

/// How long an agent gets to answer `initialize` / `session/new`.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// Database and board events, so a turn can move the card without holding
/// `AppState` (that would cycle: state owns the chats).
#[derive(Clone)]
struct BoardPipe {
    db: Arc<Mutex<rusqlite::Connection>>,
    events: broadcast::Sender<crate::board::BoardEvent>,
}

struct LiveChat {
    client: Arc<AcpClient>,
    acp_session_id: String,
    tx: broadcast::Sender<UiChunk>,
    history: Mutex<Vec<UiChunk>>,
    /// Select options from ACP `configOptions` (model, mode, …).
    config: Mutex<ConfigOptions>,
    data_dir: PathBuf,
    card_id: String,
    board: Option<BoardPipe>,
    /// Shared with the `Starting` entry so a stop during handshake is
    /// still visible once the client exists.
    cancel: Arc<AtomicBool>,
    /// The card's `pending_prompt` has been handed to this process once.
    launch_sent: AtomicBool,
    /// Process death is one error chunk, then the live entry is dropped.
    exited: AtomicBool,
}

impl LiveChat {
    /// One chunk, in order: kept for SSE replay, written to the
    /// transcript, then sent to live subscribers.
    fn record(&self, chunk: UiChunk) {
        if let Err(e) = transcript::append(&self.data_dir, &self.card_id, &chunk) {
            eprintln!("chat: failed to write transcript of {}: {e}", self.card_id);
        }
        // Push and broadcast under the history lock: `subscribe` clones
        // the history and subscribes under the same lock, so a chunk is
        // always in exactly one of a subscriber's replay or live stream.
        let mut history = self.history.lock().unwrap_or_else(|e| e.into_inner());
        history.push(chunk.clone());
        let _ = self.tx.send(chunk);
    }
}

/// A start in flight: its handshake runs outside every lock, waiters
/// park on `done` until the live chat (or the failure) is published.
struct Starting {
    done: watch::Sender<bool>,
    cancel: Arc<AtomicBool>,
}

enum Entry {
    Live(Arc<LiveChat>),
    Starting(Arc<Starting>),
}

/// Both agent surfaces' claims, under one lock so claiming either is
/// atomic against claiming the other.
#[derive(Default)]
struct Surfaces {
    chats: HashMap<String, Entry>,
    /// Cards whose PTY surface is claimed: starting, live, or between
    /// a restart and its replacement shell.
    pty: HashSet<String>,
}

struct Inner {
    surfaces: Mutex<Surfaces>,
    data_dir: PathBuf,
    /// The latest start failure for a card that never became live, so an
    /// SSE subscriber can show it. Cleared once a chat does start.
    failures: Mutex<HashMap<String, String>>,
    /// Per-card "approve permission requests automatically". Survives
    /// before the agent is live; dropped with the live chat on exit.
    approvals: Mutex<HashMap<String, bool>>,
    /// Set once the daemon (or a test) has a database. Chats started
    /// before that do not move board cards.
    board: Mutex<Option<BoardPipe>>,
    /// This daemon's address, given to every ACP child as `TABSH_URL`.
    self_url: Mutex<String>,
}

/// The outcome of a PTY surface claim (`ChatManager::try_claim_pty`).
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PtyClaim {
    /// This caller now holds the card's one agent-surface claim.
    Acquired,
    /// A PTY claim is already held for this card (a shell starting,
    /// live, or restarting): this PTY start may proceed under it.
    AlreadyPty,
    /// A chat is starting or live for this card: no PTY may start.
    BlockedByChat,
}

/// Every live chat, keyed by tabsh session (card) id. Clones share the
/// same chats, like the rest of `AppState`.
#[derive(Clone)]
pub(crate) struct ChatManager {
    inner: Arc<Inner>,
}

/// The ACP command as argv: the provider string (e.g. `cursor-agent acp`)
/// split on whitespace. Quoting is not supported in v1.
fn split_command(acp_command: &str) -> ChatResult<(String, Vec<String>)> {
    let mut parts = acp_command.split_whitespace();
    let cmd = parts
        .next()
        .ok_or_else(|| ChatError::Invalid("empty ACP command".into()))?;
    Ok((cmd.to_string(), parts.map(str::to_string).collect()))
}

impl ChatManager {
    pub(crate) fn new(data_dir: PathBuf) -> ChatManager {
        ChatManager {
            inner: Arc::new(Inner {
                surfaces: Mutex::new(Surfaces::default()),
                data_dir,
                failures: Mutex::new(HashMap::new()),
                approvals: Mutex::new(HashMap::new()),
                board: Mutex::new(None),
                self_url: Mutex::new(String::new()),
            }),
        }
    }

    /// The address shells already get as `TABSH_URL`. ACP children get
    /// the same one, overriding anything inherited from the daemon.
    pub(crate) fn bind_url(&self, url: &str) {
        *self
            .inner
            .self_url
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = url.to_string();
    }

    /// The manager for a daemon whose database is at `db_path`:
    /// transcripts live beside it. An in-memory database (tests) gets a
    /// fresh temp dir instead.
    pub(crate) fn from_db_path(db_path: &str) -> ChatManager {
        let data_dir = if db_path == ":memory:" {
            let unique = crate::auth::random_hex(8).unwrap_or_else(|_| "test".into());
            std::env::temp_dir().join(format!("tabsh-chats-{unique}"))
        } else {
            Path::new(db_path)
                .parent()
                .map(Path::to_path_buf)
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| PathBuf::from("."))
        };
        ChatManager::new(data_dir)
    }

    // Used by tests to pin the on-disk transcript location.
    #[allow(dead_code)]
    pub(crate) fn transcript_path(&self, session_id: &str) -> PathBuf {
        transcript::path(&self.inner.data_dir, session_id)
    }

    /// Wires board updates. Called once when `AppState` exists; not stored
    /// as `AppState` itself, which owns this manager.
    pub(crate) fn bind_board(
        &self,
        db: Arc<Mutex<rusqlite::Connection>>,
        events: broadcast::Sender<crate::board::BoardEvent>,
    ) {
        *self.inner.board.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(BoardPipe { db, events });
    }

    pub(crate) fn is_live(&self, session_id: &str) -> bool {
        self.live(session_id).is_some()
    }

    /// Live, or a start is handshaking (composer start / PTY claim).
    pub(crate) fn is_live_or_starting(&self, session_id: &str) -> bool {
        self.inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .chats
            .contains_key(session_id)
    }

    /// Atomically claims the card's PTY surface: succeeds only when no
    /// chat is starting or live for it. The claim holds until
    /// `release_pty`, so a chat starting at any point during the PTY's
    /// life — spawn included — loses to it, with no check-then-act gap.
    pub(crate) fn try_claim_pty(&self, session_id: &str) -> PtyClaim {
        let mut surfaces = self
            .inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if surfaces.chats.contains_key(session_id) {
            PtyClaim::BlockedByChat
        } else if !surfaces.pty.insert(session_id.to_string()) {
            PtyClaim::AlreadyPty
        } else {
            PtyClaim::Acquired
        }
    }

    /// Releases a PTY claim (`try_claim_pty`): a chat may start after.
    pub(crate) fn release_pty(&self, session_id: &str) {
        self.inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pty
            .remove(session_id);
    }

    /// Whether a PTY claim is held for the card (tests).
    #[cfg(test)]
    pub(crate) fn pty_claimed(&self, session_id: &str) -> bool {
        self.inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pty
            .contains(session_id)
    }

    fn live(&self, session_id: &str) -> Option<Arc<LiveChat>> {
        self.inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .chats
            .get(session_id)
            .and_then(|e| match e {
                Entry::Live(live) => Some(live.clone()),
                Entry::Starting(_) => None,
            })
    }

    /// Starts the card's ACP agent and, when `initial_prompt` is
    /// non-empty, sends it as a prompt. The first caller reserves the
    /// card before handshaking; concurrent callers wait for that one
    /// agent, then dispatch their own prompt to it exactly once. A
    /// failed handshake clears the reservation, and a waiter retries
    /// as the new starter.
    pub(crate) async fn start(
        &self,
        session_id: &str,
        acp_command: &str,
        cwd: &Path,
        initial_prompt: Option<&str>,
    ) -> ChatResult<()> {
        let (live, _won) = self.start_inner(session_id, acp_command, cwd, None).await?;
        if let Some(prompt) = initial_prompt.filter(|p| !p.trim().is_empty()) {
            self.dispatch(&live, prompt);
        }
        Ok(())
    }

    /// Starts the chat unless it is already live (or starting): only
    /// the caller that actually starts the agent sends the prompt, so
    /// a repeated board launch never replays it.
    pub(crate) async fn ensure_started(
        &self,
        session_id: &str,
        acp_command: &str,
        cwd: &Path,
        initial_prompt: Option<&str>,
    ) -> ChatResult<()> {
        // Settled inside `start_inner` before the chat is published, so a
        // message parked on the handshake cannot clear a stop and then
        // let this prompt be written.
        self.start_inner(session_id, acp_command, cwd, initial_prompt)
            .await?;
        Ok(())
    }

    /// The one agent for the card: `(live, this call started it)`.
    async fn start_inner(
        &self,
        session_id: &str,
        acp_command: &str,
        cwd: &Path,
        launch_prompt: Option<&str>,
    ) -> ChatResult<(Arc<LiveChat>, bool)> {
        enum Action {
            Existing(Arc<LiveChat>),
            Wait(Arc<Starting>),
            Reserve(Arc<Starting>),
            BlockedByPty,
        }
        let starting = loop {
            let action = {
                let mut surfaces = self
                    .inner
                    .surfaces
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                match surfaces.chats.get(session_id) {
                    Some(Entry::Live(live)) => Action::Existing(live.clone()),
                    Some(Entry::Starting(s)) => Action::Wait(s.clone()),
                    // The chat claim and the PTY claim are taken under
                    // this one lock: a PTY claimed first (starting or
                    // live) blocks the reservation outright, with no
                    // window for a PTY to claim in between either.
                    None if surfaces.pty.contains(session_id) => Action::BlockedByPty,
                    None => {
                        let s = Arc::new(Starting {
                            done: watch::channel(false).0,
                            cancel: Arc::new(AtomicBool::new(false)),
                        });
                        surfaces
                            .chats
                            .insert(session_id.to_string(), Entry::Starting(s.clone()));
                        Action::Reserve(s)
                    }
                }
            };
            match action {
                Action::Existing(live) => {
                    // The starter already sent the launch prompt, unless a
                    // message reserved the card first and passed none.
                    self.deliver_launch(&live, launch_prompt);
                    return Ok((live, false));
                }
                Action::Wait(s) => {
                    let mut rx = s.done.subscribe();
                    // Err only means the starter is gone; loop to retry.
                    let _ = rx.wait_for(|done| *done).await;
                }
                Action::Reserve(s) => break s,
                Action::BlockedByPty => {
                    return Err(ChatError::Conflict(format!(
                        "a PTY is live for session {session_id}"
                    )));
                }
            }
        };

        let handshake = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
            let (cmd, args) = split_command(acp_command)?;
            let url = self
                .inner
                .self_url
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            let session_token = {
                let db = self
                    .inner
                    .board
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .as_ref()
                    .map(|b| {
                        crate::sessions::store::ensure_session_token(&b.db.lock().unwrap_or_else(|e| e.into_inner()), session_id)
                    });
                match db {
                    Some(Ok(token)) => token,
                    _ => String::new(),
                }
            };
            let socket = std::path::Path::new(self.inner.data_dir.as_path())
                .parent()
                .map(|p| p.join("agent.sock"))
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let client = AcpClient::spawn_with_env(
                &cmd,
                &args,
                cwd,
                &[
                    ("TABSH_SESSION_ID", session_id),
                    ("TABSH_URL", &url),
                    ("TABSH_SESSION_TOKEN", &session_token),
                    ("TABSCTL_SOCKET", &socket),
                ],
            )
            .await
            .map_err(|e| ChatError::Failed(e.to_string()))?;
            client
                .initialize()
                .await
                .map_err(|e| ChatError::Failed(e.to_string()))?;
            let created = client
                .session_new(cwd)
                .await
                .map_err(|e| ChatError::Failed(e.to_string()))?;
            // OpenCode (and similar) can resume a backend session that still
            // holds a prompt from a prior daemon death. Clear it so the first
            // real message is not rejected with "already has an active ACP prompt".
            let _ = client.cancel(&created.session_id).await;
            client.clear_cancelled();
            Ok::<_, ChatError>((client, created))
        })
        .await
        .map_err(|_| ChatError::Failed("ACP agent handshake timed out".into()))
        .and_then(|r| r);

        let (client, created) = match handshake {
            Ok(pair) => pair,
            Err(e) => {
                let mut surfaces = self
                    .inner
                    .surfaces
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                if matches!(surfaces.chats.get(session_id), Some(Entry::Starting(s)) if Arc::ptr_eq(s, &starting))
                {
                    surfaces.chats.remove(session_id);
                }
                drop(surfaces);
                let _ = starting.done.send(true);
                return Err(e);
            }
        };

        let client = Arc::new(client);
        let mut rx = client.event_stream();
        let board = self
            .inner
            .board
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let live = Arc::new(LiveChat {
            client,
            acp_session_id: created.session_id,
            tx: broadcast::channel(256).0,
            history: Mutex::new(transcript::load(&self.inner.data_dir, session_id)),
            config: Mutex::new(created.config),
            data_dir: self.inner.data_dir.clone(),
            card_id: session_id.to_string(),
            board,
            cancel: starting.cancel.clone(),
            launch_sent: AtomicBool::new(false),
            exited: AtomicBool::new(false),
        });
        // A toggle set before the handshake finished applies to this process.
        live.client.set_auto_approve(self.approvals(session_id));
        // Archive/delete may have forgotten this start: drop the agent
        // instead of keeping a process for a card that no longer wants one.
        {
            let surfaces = self
                .inner
                .surfaces
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            match surfaces.chats.get(session_id) {
                Some(Entry::Starting(s)) if Arc::ptr_eq(s, &starting) => {}
                _ => {
                    drop(surfaces);
                    let _ = starting.done.send(true);
                    return Err(ChatError::Failed("session closed during start".into()));
                }
            }
        }
        // Stop may have landed while this was `Starting`. Settle the
        // launch prompt before the chat is live and before waiters wake:
        // a parked message must not clear the latch first.
        if live.cancel.load(Ordering::SeqCst) {
            live.client.mark_cancelled();
        }
        self.deliver_launch(&live, launch_prompt);
        {
            let mut surfaces = self
                .inner
                .surfaces
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            match surfaces.chats.get(session_id) {
                Some(Entry::Starting(s)) if Arc::ptr_eq(s, &starting) => {
                    surfaces
                        .chats
                        .insert(session_id.to_string(), Entry::Live(live.clone()));
                }
                _ => {
                    drop(surfaces);
                    let _ = starting.done.send(true);
                    return Err(ChatError::Failed("session closed during start".into()));
                }
            }
        }
        // Stop can land after `dispatch` spawned the prompt and before the
        // insert. `cancel` on `Starting` only sets the flag; copy it onto
        // the client before waiters wake. This does not clear the latch.
        if live.cancel.load(Ordering::SeqCst) {
            live.client.mark_cancelled();
        }

        // Drain agent events concurrently so chunks reach the transcript
        // and subscribers before the turn ends. Process death closes the
        // stream; trailing turn-end events that race the exit are applied
        // before the live entry is dropped.
        let weak = Arc::downgrade(&live);
        let mgr = self.clone();
        let card_id = session_id.to_string();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Some(AcpEvent::AgentExited) => {
                        let deadline = tokio::time::Instant::now() + Duration::from_millis(50);
                        loop {
                            let left =
                                deadline.saturating_duration_since(tokio::time::Instant::now());
                            if left.is_zero() {
                                break;
                            }
                            match tokio::time::timeout(left, rx.recv()).await {
                                Ok(Some(AcpEvent::AgentExited)) => continue,
                                Ok(Some(ev)) => apply_event(&weak, &ev),
                                _ => break,
                            }
                        }
                        mgr.note_agent_exit(&card_id);
                        break;
                    }
                    None => {
                        mgr.note_agent_exit(&card_id);
                        break;
                    }
                    Some(ev) => {
                        if weak.upgrade().is_none() {
                            break;
                        }
                        apply_event(&weak, &ev);
                    }
                }
            }
        });
        // Waiters were parked on the handshake. They wake only after the
        // launch prompt has been settled and the live chat is in the map.
        let _ = starting.done.send(true);
        self.clear_failure(session_id);
        Ok((live, true))
    }

    /// Records `text` as the user's chunk and runs it as an ACP prompt on
    /// a spawned task; the turn's chunks arrive through the event pump.
    /// A stop latched during handshake ends the turn here, before
    /// `prompt` can observe a later clear and write `session/prompt`.
    fn dispatch(&self, live: &Arc<LiveChat>, text: &str) {
        // Mirror the TUI UserPromptSubmit hook: a new prompt means working again.
        if let Some(board) = &live.board {
            crate::board::note_acp_prompt(&board.db, &board.events, &live.card_id);
        }
        live.record(UiChunk::UserText {
            session_id: live.acp_session_id.clone(),
            text: text.to_string(),
        });
        if live.cancel.load(Ordering::SeqCst) {
            live.record(UiChunk::TurnEnd {
                session_id: live.acp_session_id.clone(),
                stop_reason: "cancelled".into(),
            });
            return;
        }
        let client = live.client.clone();
        let acp_session_id = live.acp_session_id.clone();
        let text = text.to_string();
        let weak = Arc::downgrade(live);
        let mgr = self.clone();
        tokio::spawn(async move {
            let first = client.prompt(&acp_session_id, &text).await;
            let result = match first {
                Err(e) if prompt_busy(&e.to_string()) => {
                    // Agent still thinks a prior turn is running; cancel and
                    // try this message once more.
                    let _ = client.cancel(&acp_session_id).await;
                    client.clear_cancelled();
                    client.prompt(&acp_session_id, &text).await
                }
                other => other,
            };
            if let Err(e) = result {
                eprintln!("chat: ACP prompt failed: {e}");
                // The POST already returned 202. Auth and protocol
                // failures reach the panel only as a chunk. A dead
                // process is one error, then the live entry is dropped
                // so the next message can start again.
                let message = e.to_string();
                let Some(live) = weak.upgrade() else { return };
                if agent_gone(&message) {
                    mgr.note_agent_exit(&live.card_id);
                } else {
                    live.record(UiChunk::Error { message });
                }
            }
        });
    }

    /// Sends the card's launch prompt the first time this process is asked.
    /// A repeated board launch does not replay it; a message that reserved
    /// the card first left it unsent, and this is what delivers it.
    fn deliver_launch(&self, live: &Arc<LiveChat>, launch_prompt: Option<&str>) {
        let Some(prompt) = launch_prompt.filter(|p| !p.trim().is_empty()) else {
            return;
        };
        if live.launch_sent.swap(true, Ordering::SeqCst) {
            return;
        }
        self.dispatch(live, prompt);
    }

    /// The agent process is gone. One error chunk, then the card can start
    /// a new process on the next message. The JSONL history stays.
    fn note_agent_exit(&self, session_id: &str) {
        let Some(live) = self.live(session_id) else {
            return;
        };
        if live.exited.swap(true, Ordering::SeqCst) {
            return;
        }
        live.record(UiChunk::Error {
            message: "ACP agent exited".into(),
        });
        self.forget(session_id);
    }

    /// Remembers a start that never became a live chat, for the SSE stream.
    pub(crate) fn note_failure(&self, session_id: &str, message: &str) {
        self.inner
            .failures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session_id.to_string(), message.to_string());
    }

    pub(crate) fn failure(&self, session_id: &str) -> Option<String> {
        self.inner
            .failures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(session_id)
            .cloned()
    }

    fn clear_failure(&self, session_id: &str) {
        self.inner
            .failures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(session_id);
    }

    pub(crate) async fn send_message(&self, session_id: &str, text: &str) -> ChatResult<()> {
        let live = self.live(session_id).ok_or(ChatError::NotLive)?;
        // Stop latches the card until the user sends again. Only a message
        // that finds the chat already live clears it — see `send_keeping_stop`.
        live.cancel.store(false, Ordering::SeqCst);
        live.client.clear_cancelled();
        self.dispatch(&live, text);
        Ok(())
    }

    /// Delivers `text` without lifting a stop latched while the agent was
    /// still starting. The message route uses this after waiting out the
    /// handshake, so a parked send cannot un-cancel the launch prompt.
    pub(crate) async fn send_keeping_stop(&self, session_id: &str, text: &str) -> ChatResult<()> {
        let live = self.live(session_id).ok_or(ChatError::NotLive)?;
        self.dispatch(&live, text);
        Ok(())
    }

    /// Latches cancel for a live chat or one still handshaking (`Starting`).
    /// A live agent's in-flight prompts all end `cancelled`. With no chat
    /// yet this is a no-op.
    pub(crate) async fn cancel(&self, session_id: &str) -> ChatResult<()> {
        let client = {
            let surfaces = self
                .inner
                .surfaces
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            match surfaces.chats.get(session_id) {
                Some(Entry::Live(live)) => {
                    live.cancel.store(true, Ordering::SeqCst);
                    Some((live.client.clone(), live.acp_session_id.clone()))
                }
                Some(Entry::Starting(starting)) => {
                    starting.cancel.store(true, Ordering::SeqCst);
                    None
                }
                None => None,
            }
        };
        if let Some((client, acp_session_id)) = client {
            client
                .cancel(&acp_session_id)
                .await
                .map_err(|e| ChatError::Failed(e.to_string()))?;
        }
        Ok(())
    }

    /// Answers a `session/request_permission` the agent is blocked on, and
    /// records `permission_answered` in the transcript so the UI stays
    /// hidden across reloads. An id that is not pending still succeeds.
    pub(crate) async fn answer(
        &self,
        session_id: &str,
        request_id: &str,
        allow: bool,
    ) -> ChatResult<()> {
        if let Some(live) = self.live(session_id) {
            live.client
                .answer_permission(request_id, allow)
                .await
                .map_err(|e| ChatError::Failed(e.to_string()))?;
            live.record(UiChunk::PermissionAnswered {
                session_id: live.acp_session_id.clone(),
                request_id: request_id.to_string(),
                allow,
            });
            return Ok(());
        }
        // Agent gone: still persist so a reload does not resurrect the card.
        let acp_sid = transcript::load(&self.inner.data_dir, session_id)
            .into_iter()
            .rev()
            .find_map(|c| match c {
                UiChunk::Permission {
                    session_id: sid,
                    request_id: rid,
                    ..
                } if rid == request_id => Some(sid),
                _ => None,
            })
            .unwrap_or_default();
        transcript::append(
            &self.inner.data_dir,
            session_id,
            &UiChunk::PermissionAnswered {
                session_id: acp_sid,
                request_id: request_id.to_string(),
                allow,
            },
        )
        .map_err(|e| ChatError::Failed(e.to_string()))
    }

    /// Models the live session advertises. `None` when not live or empty.
    pub(crate) fn models(&self, session_id: &str) -> Option<ModelConfig> {
        let live = self.live(session_id)?;
        live.config
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .model
            .clone()
    }

    /// Session modes the live session advertises. `None` when not live or empty.
    pub(crate) fn modes(&self, session_id: &str) -> Option<ModeConfig> {
        let live = self.live(session_id)?;
        live.config
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .mode
            .clone()
    }

    /// Whether this card's live agent auto-approves permission requests.
    pub(crate) fn approvals(&self, session_id: &str) -> bool {
        self.inner
            .approvals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(session_id)
            .copied()
            .unwrap_or(false)
    }

    /// Sets auto-approval for this card. Works before the agent starts and
    /// updates a live process at once.
    pub(crate) fn set_approvals(&self, session_id: &str, auto: bool) {
        self.inner
            .approvals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session_id.to_string(), auto);
        if let Some(live) = self.live(session_id) {
            live.client.set_auto_approve(auto);
        }
    }

    /// Selects a model on the live ACP session. Refused while a turn is open.
    pub(crate) async fn set_model(
        &self,
        session_id: &str,
        model_id: &str,
    ) -> ChatResult<ModelConfig> {
        self.set_select(session_id, |c| c.model.as_ref(), "model", model_id)
            .await
    }

    /// Selects a session mode (how the agent asks permission) on the live
    /// ACP session. Refused while a turn is open.
    pub(crate) async fn set_mode(&self, session_id: &str, mode_id: &str) -> ChatResult<ModeConfig> {
        self.set_select(session_id, |c| c.mode.as_ref(), "mode", mode_id)
            .await
    }

    async fn set_select(
        &self,
        session_id: &str,
        pick: fn(&ConfigOptions) -> Option<&super::models::SelectConfig>,
        kind: &str,
        value: &str,
    ) -> ChatResult<super::models::SelectConfig> {
        let live = self.live(session_id).ok_or(ChatError::NotLive)?;
        {
            let history = live.history.lock().unwrap_or_else(|e| e.into_inner());
            if transcript_turn_open(&history) {
                return Err(ChatError::Invalid(format!(
                    "Wait for the current turn to finish before changing the {kind}."
                )));
            }
        }
        let config_id = {
            let config = live.config.lock().unwrap_or_else(|e| e.into_inner());
            let Some(cfg) = pick(&config) else {
                return Err(ChatError::Invalid(format!(
                    "This agent does not expose a {kind} list."
                )));
            };
            if !cfg.options.iter().any(|o| o.id == value) {
                return Err(ChatError::Invalid(format!("Unknown {kind}: {value}")));
            }
            cfg.config_id.clone()
        };
        let refreshed = live
            .client
            .set_config_option(&live.acp_session_id, &config_id, value)
            .await
            .map_err(|e| ChatError::Failed(e.to_string()))?;
        let mut config = live.config.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(next) = refreshed {
            *config = next;
        } else if let Some(cfg) = if kind == "model" {
            config.model.as_mut()
        } else {
            config.mode.as_mut()
        } {
            cfg.current = value.to_string();
        }
        pick(&config)
            .cloned()
            .ok_or_else(|| ChatError::Invalid(format!("This agent does not expose a {kind} list.")))
    }

    /// Drops the live chat, if any; the agent process dies with its last
    /// client reference (`kill_on_drop`). A handshake still running is
    /// cancelled and removed: its finish path drops the process instead of
    /// publishing a live chat (archive and delete both need that).
    pub(crate) fn forget(&self, session_id: &str) {
        let mut surfaces = self
            .inner
            .surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        match surfaces.chats.remove(session_id) {
            Some(Entry::Starting(starting)) => {
                starting.cancel.store(true, Ordering::SeqCst);
            }
            Some(Entry::Live(_)) | None => {}
        }
        drop(surfaces);
        // A fresh agent process starts at Ask, not with the last card's choice.
        self.inner
            .approvals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(session_id);
    }

    /// The assembled transcript: the live history when a chat is running,
    /// else what the transcript file holds.
    pub(crate) fn history(&self, session_id: &str) -> Vec<UiChunk> {
        match self.live(session_id) {
            Some(live) => live
                .history
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
            None => transcript::load(&self.inner.data_dir, session_id),
        }
    }

    /// History to replay plus a subscription for what comes next.
    pub(crate) fn subscribe(
        &self,
        session_id: &str,
    ) -> (Vec<UiChunk>, Option<broadcast::Receiver<UiChunk>>) {
        match self.live(session_id) {
            Some(live) => {
                // Clone and subscribe under the history lock: `record`
                // pushes and broadcasts under the same lock, so no chunk
                // can fall between the replay snapshot and the receiver.
                let history = live.history.lock().unwrap_or_else(|e| e.into_inner());
                let rx = live.tx.subscribe();
                (history.clone(), Some(rx))
            }
            None => (transcript::load(&self.inner.data_dir, session_id), None),
        }
    }
}

fn apply_event(live: &std::sync::Weak<LiveChat>, ev: &AcpEvent) {
    let Some(live) = live.upgrade() else { return };
    for chunk in to_chunks(ev) {
        live.record(chunk);
    }
    if let Some(status) = acp_card_status(ev)
        && let Some(board) = &live.board
    {
        crate::board::note_acp_status(&board.db, &board.events, &live.card_id, status);
    }
}

fn transcript_turn_open(chunks: &[UiChunk]) -> bool {
    let mut open = false;
    for chunk in chunks {
        match chunk {
            UiChunk::UserText { .. } => open = true,
            UiChunk::TurnEnd { .. } | UiChunk::Error { .. } => open = false,
            _ => {}
        }
    }
    open
}

/// A write or a waiter failed because the child is gone, not because the
/// agent rejected the prompt.
fn agent_gone(err: &str) -> bool {
    let lower = err.to_ascii_lowercase();
    lower.contains("acp agent exited")
        || lower.contains("broken pipe")
        || lower.contains("os error 32")
}

/// OpenCode (and peers) reject a new prompt while a prior one is still open
/// on the resumed session — often after a daemon restart mid-turn.
fn prompt_busy(err: &str) -> bool {
    err.to_ascii_lowercase()
        .contains("already has an active acp prompt")
}

/// Idle `end_turn` means the agent is waiting on the user. `completed` only
/// when the agent sends a session-end update. Cancel and other stop reasons
/// stay `in_progress` so a hook can still report them.
fn acp_card_status(ev: &AcpEvent) -> Option<&'static str> {
    match ev {
        AcpEvent::PromptEnded { stop_reason, .. } if stop_reason == "end_turn" => {
            Some("needs_input")
        }
        AcpEvent::SessionEnded { .. } => Some("completed"),
        _ => None,
    }
}

/// Starts a UI card's chat from its stored row: the board's launch for
/// `mode == "ui"` cards. Fire-and-forget — the agent comes up in the
/// background, exactly as a PTY launch does not block the status change.
pub(crate) fn launch_ui(st: &AppState, id: &str) {
    let st = st.clone();
    let id = id.to_string();
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => {
            handle.spawn(async move { launch_ui_async(st, id).await });
        }
        Err(_) => {
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                if let Ok(rt) = rt {
                    rt.block_on(launch_ui_async(st, id));
                }
            });
        }
    }
}

async fn launch_ui_async(st: AppState, id: String) {
    let row = st
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT mode, acp_command, pending_prompt, cwd FROM sessions WHERE id = ?1",
            params![id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .optional()
        .ok()
        .flatten();
    let Some((mode, acp_command, pending_prompt, cwd)) = row else {
        return;
    };
    if mode != "ui" {
        return;
    }
    let Some(acp) = acp_command.filter(|c| !c.trim().is_empty()) else {
        let message = "no ACP command stored for this card";
        eprintln!("chat: UI card {id} has {message}");
        st.chats.note_failure(&id, message);
        return;
    };
    // One active agent surface per card: never over a live agent PTY.
    // A chat that is already live still falls through: `ensure_started`
    // sends `pending_prompt` once if this process has not had it.
    if st.live.lock().unwrap().contains_key(&id) {
        eprintln!("chat: refusing to start over the live PTY of {id}");
        st.chats
            .note_failure(&id, "This card already has a terminal running.");
        return;
    }
    let cwd = cwd.map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    match st
        .chats
        .ensure_started(&id, &acp, &cwd, pending_prompt.as_deref())
        .await
    {
        Ok(()) => {
            // The prompt has been handed to the agent; it is no longer
            // pending. `acp_command` stays, so later messages can restart
            // the chat after a daemon restart.
            if let Err(e) = st.db.lock().unwrap().execute(
                "UPDATE sessions SET pending_input = NULL, pending_prompt = NULL,
                     pending_command = NULL WHERE id = ?1",
                params![id],
            ) {
                eprintln!("chat: failed to clear pending prompt of {id}: {e}");
            }
        }
        Err(e) => {
            eprintln!("chat: failed to start UI card {id}: {e}");
            st.chats.note_failure(&id, &e.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_acp_command() -> String {
        let (cmd, args) = crate::chat::acp::fake_agent();
        format!("{cmd} {}", args.join(" "))
    }

    fn test_manager() -> ChatManager {
        let unique = crate::auth::random_hex(8).unwrap_or_else(|_| "test".into());
        ChatManager::new(std::env::temp_dir().join(format!("tabsh-chats-test-{unique}")))
    }

    fn user_texts(chunks: &[UiChunk]) -> Vec<String> {
        chunks
            .iter()
            .filter_map(|c| match c {
                UiChunk::UserText { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect()
    }

    fn all_text(chunks: &[UiChunk]) -> String {
        chunks
            .iter()
            .filter_map(|c| serde_json::to_value(c).ok())
            .filter_map(|v| v["text"].as_str().map(str::to_string))
            .collect()
    }

    #[tokio::test]
    async fn concurrent_starts_spawn_one_agent_and_dispatch_both_prompts() {
        let chats = test_manager();
        let cmd = fake_acp_command();
        let cwd = Path::new("/tmp");
        let (a, b) = tokio::join!(
            chats.start("card-1", &cmd, cwd, Some("one")),
            chats.start("card-1", &cmd, cwd, Some("two")),
        );
        a.unwrap();
        b.unwrap();
        assert!(chats.is_live("card-1"));

        // Both prompts answered by the one agent; neither dropped, neither doubled.
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            let history = chats.history("card-1");
            let text = all_text(&history);
            if text.contains("fake reply: one") && text.contains("fake reply: two") {
                let mut sent = user_texts(&history);
                sent.sort();
                assert_eq!(sent, vec!["one".to_string(), "two".to_string()]);
                break;
            }
            assert!(std::time::Instant::now() < deadline, "history: {text}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        chats.forget("card-1");
    }

    #[tokio::test]
    async fn pty_claim_blocks_chat_start_until_released() {
        let chats = test_manager();
        assert_eq!(chats.try_claim_pty("card-p"), PtyClaim::Acquired);
        assert_eq!(chats.try_claim_pty("card-p"), PtyClaim::AlreadyPty);
        let cmd = fake_acp_command();
        let err = chats
            .start("card-p", &cmd, Path::new("/tmp"), Some("hi"))
            .await
            .unwrap_err();
        assert!(matches!(err, ChatError::Conflict(_)), "start: {err}");
        assert!(!chats.is_live_or_starting("card-p"), "no chat reserved");
        chats.release_pty("card-p");
        assert!(!chats.pty_claimed("card-p"));
        chats
            .start("card-p", &cmd, Path::new("/tmp"), Some("hi"))
            .await
            .unwrap();
        assert!(chats.is_live("card-p"));
        // And while the chat is live, the PTY claim loses.
        assert_eq!(chats.try_claim_pty("card-p"), PtyClaim::BlockedByChat);
        chats.forget("card-p");
        assert_eq!(chats.try_claim_pty("card-p"), PtyClaim::Acquired);
        chats.release_pty("card-p");
    }

    // The race itself: a PTY claim and a chat start released at the
    // same instant must produce exactly one winner, every time.
    #[tokio::test]
    async fn concurrent_pty_claim_and_chat_start_have_one_winner() {
        let chats = test_manager();
        let cmd = fake_acp_command();
        for n in 0..16 {
            let id = format!("race-{n}");
            let barrier = Arc::new(tokio::sync::Barrier::new(2));
            let claim = {
                let chats = chats.clone();
                let barrier = barrier.clone();
                let id = id.clone();
                tokio::spawn(async move {
                    barrier.wait().await;
                    chats.try_claim_pty(&id)
                })
            };
            let start = {
                let chats = chats.clone();
                let barrier = barrier.clone();
                let cmd = cmd.clone();
                let id = id.clone();
                tokio::spawn(async move {
                    barrier.wait().await;
                    chats.start(&id, &cmd, Path::new("/tmp"), None).await
                })
            };
            let claim = claim.await.unwrap();
            let started = start.await.unwrap();
            match claim {
                PtyClaim::Acquired | PtyClaim::AlreadyPty => {
                    assert!(
                        matches!(started, Err(ChatError::Conflict(_))),
                        "PTY claimed {id} but chat also started: {started:?}"
                    );
                    assert!(!chats.is_live(&id));
                    chats.release_pty(&id);
                }
                PtyClaim::BlockedByChat => {
                    started.unwrap_or_else(|e| panic!("chat won {id} but failed: {e}"));
                    assert!(chats.is_live(&id));
                    chats.forget(&id);
                }
            }
            assert!(!chats.is_live_or_starting(&id) && !chats.pty_claimed(&id));
        }
    }

    #[tokio::test]
    async fn failed_start_clears_the_reservation() {
        let chats = test_manager();
        assert!(
            chats
                .start(
                    "card-x",
                    "/nonexistent-agent-xyz acp",
                    Path::new("/tmp"),
                    Some("hi")
                )
                .await
                .is_err()
        );
        assert!(!chats.is_live_or_starting("card-x"));
        // A later start with a working command succeeds on the same card.
        let cmd = fake_acp_command();
        chats
            .start("card-x", &cmd, Path::new("/tmp"), Some("hi"))
            .await
            .unwrap();
        assert!(chats.is_live("card-x"));
        chats.forget("card-x");
    }
}
