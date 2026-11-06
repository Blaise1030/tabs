//! Starting shells in PTYs and reading their output into the scrollback.

use super::{
    Event, Output, SCROLLBACK_BYTES, Session,
    activity::Signals,
    modes::{ModeTracker, RESTORE_MARKER},
};
use crate::{AppState, error::BoxError};
use axum::body::Bytes;
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use rusqlite::{OptionalExtension, params};
use std::{
    collections::{HashSet, VecDeque},
    io::{Read, Write},
    sync::{
        Arc, Condvar, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::broadcast;

/// Set once the daemon is exiting: shells dying because of that must not
/// count as the user closing them, so their rows are kept for next start.
pub(crate) static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "linux")]
pub(super) fn process_cwd(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()?
        .into_os_string()
        .into_string()
        .ok()
}

#[cfg(target_os = "macos")]
pub(super) fn process_cwd(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let n = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    if n != size {
        return None;
    }
    let path = unsafe { std::ffi::CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) };
    path.to_str().ok().map(String::from)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(super) fn process_cwd(_pid: u32) -> Option<String> {
    None
}

/// What every shell gets in its environment: hooks and `tabsh status` read
/// `TABSH_SESSION_ID` to know which card they belong to. A new card's first
/// prompt rides along as `TABSH_PROMPT` (the typed line only names it).
///
/// `TABSH_SESSION_TOKEN` is that card's own bearer — enough for
/// `tabsh status`, not the pairing token. `TABSCTL_SOCKET` finds the
/// browser without pointing at `TABSH_DB` (and the pairing token beside it).
pub(super) fn shell_env(
    st: &AppState,
    id: &str,
    prompt: Option<&str>,
) -> Vec<(&'static str, String)> {
    let token = {
        let db = st.db.lock().unwrap_or_else(|e| e.into_inner());
        crate::sessions::store::ensure_session_token(&db, id).unwrap_or_default()
    };
    let socket = std::path::Path::new(st.db_path.as_ref())
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("agent.sock"))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut env = vec![
        ("TERM", "xterm-256color".into()),
        ("TABSH_SESSION_ID", id.into()),
        ("TABSH_URL", st.self_url.to_string()),
        ("TABSH_SESSION_TOKEN", token),
        ("TABSCTL_SOCKET", socket),
    ];
    if let Some(p) = prompt {
        env.push(("TABSH_PROMPT", p.into()));
    }
    env
}

/// Sessions whose shell is being started, restarted or closed, one at a time
/// per session: two attaches never start two shells, and a close or restart
/// never misses a shell mid-start. Other sessions never wait on it, nor on
/// the slow part of a start (`openpty`, fork), which holds no other lock.
#[derive(Default)]
pub(crate) struct Starting {
    busy: Mutex<HashSet<String>>,
    done: Condvar,
}

/// One session's turn at [`Starting`], until dropped.
pub(super) struct Turn<'a> {
    starting: &'a Starting,
    id: String,
}

impl Starting {
    /// Waits for `id`'s turn: until no one else starts, restarts or closes
    /// its shell.
    pub(super) fn turn(&self, id: &str) -> Turn<'_> {
        let mut busy = self.busy.lock().unwrap();
        while busy.contains(id) {
            busy = self.done.wait(busy).unwrap();
        }
        busy.insert(id.to_owned());
        Turn {
            starting: self,
            id: id.to_owned(),
        }
    }
}

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        self.starting.busy.lock().unwrap().remove(&self.id);
        self.starting.done.notify_all();
    }
}

/// [`get_or_spawn`] for async handlers: on the blocking pool, so the worker
/// moves on while the shell starts.
pub(crate) async fn open(st: AppState, id: String) -> Result<Option<Arc<Session>>, BoxError> {
    tokio::task::spawn_blocking(move || get_or_spawn(&st, &id)).await?
}

/// Return the running shell for `id`, starting it (in its saved cwd, with its
/// saved scrollback) if the session exists but isn't running yet. Blocks:
/// async code calls [`open`].
pub(crate) fn get_or_spawn(st: &AppState, id: &str) -> Result<Option<Arc<Session>>, BoxError> {
    let running = || st.live.lock().unwrap().get(id).cloned();
    if let Some(s) = running() {
        return Ok(Some(s));
    }
    let _turn = st.starting.turn(id);
    // Started by whoever had the turn before.
    if let Some(s) = running() {
        return Ok(Some(s));
    }
    // One active agent surface per card, claimed atomically in the
    // ChatManager: this claim and a chat's reservation are taken under
    // the same lock, so whichever surface claims first wins and the
    // other is refused — no recheck window remains. The claim holds
    // for the shell's whole life (a restart's replacement proceeds
    // under `AlreadyPty`); the reader thread releases it on exit, and
    // `close` releases it when no shell is live.
    match st.chats.try_claim_pty(id) {
        crate::chat::PtyClaim::BlockedByChat => {
            return Err(format!("a chat is live for session {id}").into());
        }
        crate::chat::PtyClaim::Acquired | crate::chat::PtyClaim::AlreadyPty => {}
    }
    let row = match st
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT cwd, scrollback, status, pending_prompt, pending_input, resume_input
             FROM sessions WHERE id = ?1",
            params![id],
            |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            },
        )
        .optional()
    {
        Ok(row) => row,
        Err(e) => {
            st.chats.release_pty(id);
            return Err(e.into());
        }
    };
    let Some((cwd, scrollback, status, prompt, pending, resume)) = row else {
        st.chats.release_pty(id);
        return Ok(None);
    };
    let shell = user_shell();
    let session = match spawn_session(
        st.clone(),
        id.to_owned(),
        &shell,
        cwd,
        scrollback,
        prompt.as_deref(),
    ) {
        Ok(session) => session,
        Err(e) => {
            st.chats.release_pty(id);
            return Err(e);
        }
    };
    match startup_input(&status, pending.is_some(), resume) {
        Startup::Launch => type_launch_line(st, id, &session),
        Startup::Resume(line) => {
            let _ = session.input.send(Bytes::from(line));
        }
        Startup::Nothing => {}
    }
    register(st, id, &session);
    Ok(Some(session))
}

/// Puts a started shell in `live`. One that already ended found nothing
/// there to forget when it did: it is forgotten here instead.
fn register(st: &AppState, id: &str, session: &Arc<Session>) {
    st.live
        .lock()
        .unwrap()
        .insert(id.to_owned(), session.clone());
    if session.output.lock().unwrap().exited {
        let mut live = st.live.lock().unwrap();
        if live.get(id).is_some_and(|x| Arc::ptr_eq(x, session)) {
            live.remove(id);
        }
    }
}

#[derive(Debug, PartialEq)]
enum Startup {
    /// The card's agent hasn't started yet: type its launch line.
    Launch,
    /// tabsh restarted under a running agent: reopen its conversation.
    Resume(String),
    Nothing,
}

/// What a session's fresh shell is sent first. A started card keeps its
/// session in every column but Archived, Backlog included when it was parked
/// back there; a card that never started (its launch still pending) waits
/// in Backlog for its drag to In progress.
fn startup_input(status: &str, pending: bool, resume: Option<String>) -> Startup {
    match (status, resume) {
        ("in_progress", _) if pending => Startup::Launch,
        ("in_progress" | "needs_input" | "completed" | "backlog", Some(line)) if !pending => {
            Startup::Resume(line)
        }
        _ => Startup::Nothing,
    }
}

/// Types a card's pending launch line into its shell, once. The PTY buffers
/// it until the shell reads its first line, so this is safe to send before
/// the prompt is drawn.
pub(super) fn type_launch_line(st: &AppState, id: &str, session: &Session) {
    let db = st.db.lock().unwrap();
    let line = db
        .query_row(
            "SELECT pending_input FROM sessions WHERE id = ?1",
            params![id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten();
    let Some(line) = line else { return };
    if let Err(e) = db.execute(
        "UPDATE sessions SET pending_input = NULL, pending_prompt = NULL, pending_command = NULL WHERE id = ?1",
        params![id],
    ) {
        eprintln!("failed to clear pending input of {id}: {e}");
    }
    let _ = session.input.send(Bytes::from(line));
}

impl Output {
    pub(super) fn new(scrollback: VecDeque<u8>) -> Self {
        Output {
            total: scrollback.len() as u64,
            scrollback,
            trimmed_modes: ModeTracker::default(),
            tx: broadcast::channel(1024).0,
            exited: false,
            dirty: false,
            epoch: new_epoch(),
        }
    }

    /// One chunk the shell wrote: kept in the scrollback (its oldest bytes
    /// trimmed, their modes remembered) and sent to attached clients. Both
    /// happen under the `output` lock so a client attaching (`replay`) sees
    /// each byte once, in its history or live; neither waits on a client.
    pub(super) fn append(&mut self, chunk: Bytes, bell: bool) {
        self.scrollback.extend(&chunk[..]);
        let excess = self.scrollback.len().saturating_sub(SCROLLBACK_BYTES);
        self.trimmed_modes.feed(self.scrollback.drain(..excess));
        self.dirty = true;
        self.total += chunk.len() as u64;
        let _ = self.tx.send(Event::Output(chunk));
        if bell {
            let _ = self.tx.send(Event::Bell);
        }
    }

    /// The scrollback as one buffer, for a replay or a save.
    pub(super) fn scrollback_bytes(&self) -> Vec<u8> {
        self.scrollback_from(0)
    }

    /// The scrollback from its `skip`th byte on. Callers hold the `output`
    /// lock, which the reader needs for every chunk, so the ring's two halves
    /// are copied whole rather than walked byte by byte.
    pub(super) fn scrollback_from(&self, skip: usize) -> Vec<u8> {
        let (front, back) = self.scrollback.as_slices();
        let mut bytes = Vec::with_capacity(self.scrollback.len().saturating_sub(skip));
        bytes.extend_from_slice(front.get(skip..).unwrap_or_default());
        bytes.extend_from_slice(&back[skip.saturating_sub(front.len()).min(back.len())..]);
        bytes
    }
}

/// A name for a new output's byte count, unique across shells and daemon
/// runs: the daemon's start time and a counter.
fn new_epoch() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    static START: OnceLock<u128> = OnceLock::new();
    let start = START.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos())
    });
    format!("{start:x}-{:x}", NEXT.fetch_add(1, Ordering::Relaxed))
}

/// The shell terminals run: `$SHELL`, else the account's login shell (a
/// launchd service such as `brew services start tabsh` has no `$SHELL`),
/// else /bin/sh.
pub(crate) fn user_shell() -> String {
    match std::env::var("SHELL") {
        Ok(shell) if !shell.is_empty() => shell,
        _ => login_shell().unwrap_or_else(|| "/bin/sh".into()),
    }
}

fn login_shell() -> Option<String> {
    let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buf = vec![0 as libc::c_char; 4096];
    let mut found = std::ptr::null_mut();
    let rc = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut pw,
            buf.as_mut_ptr(),
            buf.len(),
            &mut found,
        )
    };
    if rc != 0 || found.is_null() || pw.pw_shell.is_null() {
        return None;
    }
    let shell = unsafe { std::ffi::CStr::from_ptr(pw.pw_shell) }
        .to_str()
        .ok()?;
    (!shell.is_empty()).then(|| shell.to_owned())
}

fn spawn_session(
    st: AppState,
    id: String,
    shell: &str,
    cwd: Option<String>,
    saved: Vec<u8>,
    prompt: Option<&str>,
) -> Result<Arc<Session>, BoxError> {
    let pair = native_pty_system().openpty(PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    let mut cmd = CommandBuilder::new(shell);
    cmd.arg("-l");
    // Shells must not inherit the daemon's `TABSH_DB`: that path sits beside
    // the pairing token, and a coding agent in the card would otherwise
    // hold full daemon credentials. The card's own session token is enough.
    cmd.env_remove("TABSH_DB");
    for (k, v) in shell_env(&st, &id, prompt) {
        cmd.env(k, v);
    }
    let dir = cwd
        .filter(|d| std::path::Path::new(d).is_dir())
        .map(Into::into)
        .or_else(|| std::env::var_os("HOME"));
    if let Some(dir) = dir {
        cmd.cwd(dir);
    }
    let mut child = pair.slave.spawn_command(cmd)?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader()?;
    let mut writer = pair.master.take_writer()?;

    // PTY I/O is blocking, so it lives on dedicated threads.
    let (input, in_rx) = std::sync::mpsc::channel::<Bytes>();
    std::thread::spawn(move || {
        while let Ok(data) = in_rx.recv() {
            if writer.write_all(&data).is_err() {
                break;
            }
        }
    });

    let mut scrollback = VecDeque::from(saved);
    if !scrollback.is_empty() {
        scrollback.extend(RESTORE_MARKER);
    }
    let session = Arc::new(Session {
        master: Mutex::new(pair.master),
        input,
        killer: Mutex::new(child.clone_killer()),
        pid: child.process_id(),
        restarting: AtomicBool::new(false),
        retaining: AtomicBool::new(false),
        output: Mutex::new(Output::new(scrollback)),
    });

    let s = session.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let signals = Signals::start(st.events.clone(), id.clone());
        while let Ok(n @ 1..) = reader.read(&mut buf) {
            // Parked tabs hear this instead of the output; outside the lock.
            let bell = signals.feed(&buf[..n]);
            // Copied before the lock: attaching clients and the flusher wait
            // on it, so it covers only the append and the broadcast.
            let chunk = Bytes::copy_from_slice(&buf[..n]);
            s.output.lock().unwrap().append(chunk, bell);
        }
        // Sends output held back in its last second; stops its sweeper.
        drop(signals);
        // Shell exited (or was killed): reap it, tell clients, forget the session.
        let _ = child.wait();
        if SHUTTING_DOWN.load(Ordering::SeqCst) {
            return;
        }
        // A restart swapped this shell out (its card's first prompt changed):
        // the session stays for its replacement, and its tabs reattach to it
        // instead of closing. Archive kills with `retaining`: the card row
        // stays, with no replacement and no reattach.
        let restarting = s.restarting.load(Ordering::SeqCst);
        let retaining = s.retaining.load(Ordering::SeqCst);
        let mut out = s.output.lock().unwrap();
        out.exited = true;
        let _ = out.tx.send(if restarting {
            Event::Restart
        } else {
            Event::Exit
        });
        drop(out);
        // A replacement may already be running under this id: forget only
        // this session.
        {
            let mut live = st.live.lock().unwrap();
            if live.get(&id).is_some_and(|x| Arc::ptr_eq(x, &s)) {
                live.remove(&id);
            }
        }
        if restarting {
            // The PTY claim stays: the replacement shell runs under it.
            return;
        }
        // The shell is gone: release its PTY surface claim so a chat
        // may start for this card from here on.
        st.chats.release_pty(&id);
        if retaining {
            // Archived: the card stays; side terminals were closed with it.
            return;
        }
        // A card's exit takes its side terminals. Not on restart: the row stays.
        super::forget_exited(&st, &id);
    });

    Ok(session)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::test_state;

    #[test]
    fn scrollback_bytes_are_the_wrapped_ring_in_order() {
        // Bytes pushed in front of the start wrap to the end of the buffer.
        let mut ring = VecDeque::with_capacity(64);
        ring.extend(*b"world");
        for &b in b"hello, ".iter().rev() {
            ring.push_front(b);
        }
        let out = Output::new(ring);
        let (front, back) = out.scrollback.as_slices();
        assert!(!front.is_empty() && !back.is_empty(), "the ring wrapped");
        assert_eq!(out.scrollback_bytes(), b"hello, world");
    }

    #[test]
    fn appending_keeps_the_newest_scrollback_and_the_modes_trimmed_off() {
        let mut out = Output::new(VecDeque::new());
        let mut rx = out.tx.subscribe();
        out.append(Bytes::from_static(b"\x1b[?1049h"), false);
        out.append(Bytes::from(vec![b'x'; SCROLLBACK_BYTES]), false);
        assert_eq!(out.scrollback.len(), SCROLLBACK_BYTES);
        assert!(out.scrollback.iter().all(|&b| b == b'x'));
        assert_eq!(out.trimmed_modes.replay_prefix(), b"\x1b[?1049h");
        assert!(out.dirty);
        let sent: Vec<usize> = std::iter::from_fn(|| match rx.try_recv() {
            Ok(Event::Output(data)) => Some(data.len()),
            _ => None,
        })
        .collect();
        assert_eq!(
            sent,
            [8, SCROLLBACK_BYTES],
            "each chunk broadcast once, whole"
        );
    }

    #[test]
    fn a_bell_is_broadcast_after_the_output_it_was_in() {
        let mut out = Output::new(VecDeque::new());
        let mut rx = out.tx.subscribe();
        out.append(Bytes::from_static(b"done\x07"), true);
        assert!(matches!(
            rx.try_recv(),
            Ok(Event::Output(data)) if &data[..] == b"done\x07"
        ));
        assert!(matches!(rx.try_recv(), Ok(Event::Bell)));
        out.append(Bytes::from_static(b"quiet"), false);
        assert!(matches!(rx.try_recv(), Ok(Event::Output(_))));
        assert!(rx.try_recv().is_err(), "quiet output sends no bell");
    }

    #[test]
    fn the_login_shell_comes_from_the_account() {
        let shell = login_shell().expect("this account has a login shell");
        assert!(std::path::Path::new(&shell).is_absolute(), "{shell}");
    }

    #[test]
    fn shells_know_their_card_and_the_daemon() {
        let st = test_state();
        let id = crate::sessions::store::insert_session(&st.db.lock().unwrap(), None)
            .unwrap()
            .id;
        let env = shell_env(&st, &id, None);
        assert!(!env.iter().any(|(k, _)| *k == "TABSH_PROMPT"));
        assert!(env.contains(&("TERM", "xterm-256color".into())));
        assert!(env.contains(&("TABSH_SESSION_ID", id.clone())));
        assert!(env.contains(&("TABSH_URL", "http://127.0.0.1:7681".into())));
        let token = env
            .iter()
            .find(|(k, _)| *k == "TABSH_SESSION_TOKEN")
            .map(|(_, v)| v.as_str())
            .unwrap_or("");
        assert!(token.len() >= 32, "shells get a session token, not the pairing token");
        assert_ne!(token, st.token.as_ref());
        assert!(env.iter().any(|(k, _)| *k == "TABSCTL_SOCKET"));
    }

    #[test]
    fn a_pending_prompt_reaches_the_shell_verbatim() {
        let st = test_state();
        let id = crate::sessions::store::insert_session(&st.db.lock().unwrap(), None)
            .unwrap()
            .id;
        let p = "it's $(x) `y`\n\"z\"";
        let env = shell_env(&st, &id, Some(p));
        assert!(env.contains(&("TABSH_PROMPT", p.into())));
    }

    fn pending(st: &AppState, id: &str) -> Option<String> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                [id],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn a_backlog_shell_keeps_its_launch_line_until_the_card_is_in_progress() {
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
        let session = get_or_spawn(&st, &id).unwrap().unwrap();
        assert_eq!(pending(&st, &id).as_deref(), Some("true\r"));
        st.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET status = 'in_progress' WHERE id = ?1",
                [&id],
            )
            .unwrap();
        crate::sessions::launch(&st, &id);
        assert_eq!(pending(&st, &id), None, "typed once");
        let _ = session.killer.lock().unwrap().kill();
    }

    // A board drag (or New card in In progress) launches with no browser
    // socket attached: the shell must start then, so the agent runs while the
    // page shows only the board.
    #[test]
    fn launch_starts_a_shell_that_was_not_running() {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                pending: Some("true\r"),
                prompt: Some("go"),
                status: "in_progress",
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        assert!(st.live.lock().unwrap().get(&id).is_none());
        crate::sessions::launch(&st, &id);
        assert!(
            st.live.lock().unwrap().get(&id).is_some(),
            "launch spawned the shell"
        );
        assert_eq!(pending(&st, &id), None, "typed the launch line");
        let session = st.live.lock().unwrap().get(&id).unwrap().clone();
        let _ = session.killer.lock().unwrap().kill();
    }

    #[test]
    fn a_restart_swaps_the_shell_but_keeps_the_card_and_its_pending_prompt() {
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
        let first = get_or_spawn(&st, &id).unwrap().unwrap();
        crate::sessions::restart(&st, &id);
        let second = get_or_spawn(&st, &id).unwrap().unwrap();
        assert!(
            !Arc::ptr_eq(&first, &second),
            "the next attach gets a fresh shell"
        );
        assert_eq!(
            pending(&st, &id).as_deref(),
            Some("true\r"),
            "still waiting for the drag to In progress"
        );
        let alive: i64 = st
            .db
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM sessions WHERE id = ?1", [&id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(alive, 1, "the card survives its shell");
        let _ = second.killer.lock().unwrap().kill();
    }

    fn new_card(st: &AppState) -> String {
        crate::sessions::store::insert_session(&st.db.lock().unwrap(), None)
            .unwrap()
            .id
    }

    fn kill(session: &Session) {
        let _ = session.killer.lock().unwrap().kill();
    }

    /// Waits up to 10s for `done`.
    fn eventually(done: impl Fn() -> bool) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !done() {
            if std::time::Instant::now() > deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        true
    }

    // A tab's socket starts its shell on the blocking pool: the async worker
    // that took the request moves on (here, the only one) while the spawn
    // waits on the database or on `openpty`.
    #[test]
    fn a_socket_starts_its_shell_off_the_async_workers() {
        let st = test_state();
        let id = new_card(&st);
        let (free, session) = crate::test_support::off_the_worker(&st, open(st.clone(), id));
        kill(&session.unwrap().unwrap());
        assert!(free, "the worker was free while the shell started");
    }

    // Opening one tab's shell doesn't hold `live`, which every other tab's
    // attach, cwd and close needs, while it waits to read its card. (This
    // covers the database wait only; fork and `openpty` hold no lock either,
    // but aren't slow enough here to observe.)
    #[test]
    fn starting_a_shell_leaves_the_other_sessions_free() {
        let st = test_state();
        let id = new_card(&st);
        let holder = crate::test_support::hold_db(&st, std::time::Duration::from_millis(400));
        let opening = {
            let (st, id) = (st.clone(), id.clone());
            std::thread::spawn(move || get_or_spawn(&st, &id).unwrap().unwrap())
        };
        // Past the opener's brief look in `live`, to its wait for the card.
        std::thread::sleep(std::time::Duration::from_millis(30));
        let t0 = std::time::Instant::now();
        let mut busy = 0;
        while t0.elapsed() < std::time::Duration::from_millis(250) {
            busy += usize::from(st.live.try_lock().is_err());
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        holder.join().unwrap();
        kill(&opening.join().unwrap());
        // Held throughout, `live` would be busy on every one of ~25 looks.
        assert!(busy <= 1, "`live` stayed free while the shell started");
    }

    // A shell that ends before it is registered in `live` (here `true`,
    // which exits at once) found nothing there to forget: registering it
    // must not leave it there for good.
    #[test]
    fn a_shell_that_ended_before_it_was_registered_is_not_left_running() {
        let st = test_state();
        let id = new_card(&st);
        let session = spawn_session(st.clone(), id.clone(), "true", None, vec![], None).unwrap();
        // Marked here rather than awaited: under the parallel suite the
        // reader can take seconds to see `true` end (#91), and this test is
        // about `register`, not exit detection.
        session.output.lock().unwrap().exited = true;
        register(&st, &id, &session);
        assert!(
            !st.live.lock().unwrap().contains_key(&id),
            "the ended shell was forgotten"
        );
    }

    // A shell holds its card's agent-surface claim for its whole life:
    // a chat cannot claim the card until the shell has exited.
    #[test]
    fn a_shell_claims_its_surface_until_it_exits() {
        let st = test_state();
        let id = new_card(&st);
        let session = get_or_spawn(&st, &id).unwrap().unwrap();
        assert!(st.chats.pty_claimed(&id), "the shell claimed its card");
        assert_eq!(
            st.chats.try_claim_pty(&id),
            crate::chat::PtyClaim::AlreadyPty
        );
        kill(&session);
        assert!(
            eventually(|| !st.chats.pty_claimed(&id)),
            "the claim was released when the shell exited"
        );
        assert_eq!(st.chats.try_claim_pty(&id), crate::chat::PtyClaim::Acquired);
        st.chats.release_pty(&id);
    }

    // Tabs attaching to one session at once share one shell.
    #[test]
    fn concurrent_opens_of_a_session_start_one_shell() {
        let st = test_state();
        let id = new_card(&st);
        let opens: Vec<_> = (0..8)
            .map(|_| {
                let (st, id) = (st.clone(), id.clone());
                std::thread::spawn(move || get_or_spawn(&st, &id).unwrap().unwrap())
            })
            .collect();
        let shells: Vec<_> = opens.into_iter().map(|t| t.join().unwrap()).collect();
        let first = &shells[0];
        assert!(shells.iter().all(|s| Arc::ptr_eq(s, first)), "one shell");
        assert!(Arc::ptr_eq(
            st.live.lock().unwrap().get(&id).unwrap(),
            first
        ));
        kill(first);
    }

    // A tab closed while its shell is starting doesn't leave that shell
    // running with no card.
    #[test]
    fn closing_a_tab_while_its_shell_starts_ends_that_shell() {
        let st = test_state();
        let id = new_card(&st);
        let holder = crate::test_support::hold_db(&st, std::time::Duration::from_millis(300));
        let opening = {
            let (st, id) = (st.clone(), id.clone());
            std::thread::spawn(move || get_or_spawn(&st, &id))
        };
        std::thread::sleep(std::time::Duration::from_millis(50));
        let closing = {
            let (st, id) = (st.clone(), id.clone());
            std::thread::spawn(move || {
                tokio::runtime::Builder::new_current_thread()
                    .build()
                    .unwrap()
                    .block_on(crate::sessions::delete_session(
                        axum::extract::State(st),
                        axum::extract::Path(id),
                    ))
            })
        };
        holder.join().unwrap();
        let _ = opening.join().unwrap();
        closing.join().unwrap();
        assert!(
            eventually(|| !st.live.lock().unwrap().contains_key(&id)),
            "no shell left running"
        );
        assert!(!crate::sessions::exists(&st, &id), "the card is gone");
    }

    // A restart (an edited first prompt) while the shell is starting
    // replaces the shell that started.
    #[test]
    fn a_restart_while_the_shell_starts_replaces_it() {
        let st = test_state();
        let id = new_card(&st);
        let holder = crate::test_support::hold_db(&st, std::time::Duration::from_millis(300));
        let opening = {
            let (st, id) = (st.clone(), id.clone());
            std::thread::spawn(move || get_or_spawn(&st, &id).unwrap().unwrap())
        };
        std::thread::sleep(std::time::Duration::from_millis(50));
        let restarting = {
            let (st, id) = (st.clone(), id.clone());
            std::thread::spawn(move || crate::sessions::restart(&st, &id))
        };
        holder.join().unwrap();
        let started = opening.join().unwrap();
        restarting.join().unwrap();
        assert!(
            started.restarting.load(Ordering::SeqCst),
            "the shell that started was restarted"
        );
        assert!(
            !st.live
                .lock()
                .unwrap()
                .get(&id)
                .is_some_and(|s| Arc::ptr_eq(s, &started)),
            "and is no longer the live one"
        );
        kill(&started);
    }

    #[test]
    fn a_restart_resumes_the_agent_of_a_started_card_outside_archived() {
        let line = || Some("claude --resume s-1\r".to_owned());
        // Backlog too: a started card parked back there has run, so it
        // keeps its session.
        for status in ["in_progress", "needs_input", "completed", "backlog"] {
            assert_eq!(
                startup_input(status, false, line()),
                Startup::Resume("claude --resume s-1\r".into())
            );
        }
        assert_eq!(startup_input("archived", false, line()), Startup::Nothing);
        assert_eq!(
            startup_input("backlog", true, line()),
            Startup::Nothing,
            "a Backlog card that never started waits for its drag"
        );
        assert_eq!(startup_input("in_progress", false, None), Startup::Nothing);
        assert_eq!(
            startup_input("in_progress", true, line()),
            Startup::Launch,
            "an agent that never started is launched, not resumed"
        );
        assert_eq!(startup_input("backlog", true, None), Startup::Nothing);
    }

    #[test]
    fn a_restored_shell_types_its_resume_line() {
        assert_restore_types_resume_line("needs_input");
    }

    #[test]
    fn a_started_card_parked_in_backlog_resumes_after_a_restart() {
        assert_restore_types_resume_line("backlog");
    }

    /// A card in `status` whose agent reported its conversation, and has no
    /// launch pending, gets its resume line typed into the fresh shell.
    fn assert_restore_types_resume_line(status: &str) {
        let st = test_state();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                status,
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        st.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET resume_input = 'true tabsh-resume-test\r' WHERE id = ?1",
                [&id],
            )
            .unwrap();
        let session = get_or_spawn(&st, &id).unwrap().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let ran = loop {
            let out: Vec<u8> = session
                .output
                .lock()
                .unwrap()
                .scrollback
                .iter()
                .copied()
                .collect();
            // The terminal echoes what's typed even before a slow login
            // shell draws its prompt.
            if String::from_utf8_lossy(&out).contains("tabsh-resume-test") {
                break true;
            }
            if std::time::Instant::now() > deadline {
                break false;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        let _ = session.killer.lock().unwrap().kill();
        assert!(ran, "the resume line was typed into the fresh shell");
    }
}
