//! The SQLite database: which sessions exist, their saved scrollback and cwd.

use super::{Session, SessionInfo, pty::process_cwd};
use crate::{AppState, error::BoxError};
use rusqlite::{Connection, OptionalExtension, params};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};

/// Makes the database, which holds device tokens, readable by its owner only.
/// SQLite gives the journal files it creates the database's mode; ones left
/// from an earlier run are fixed here.
fn owner_only(path: &str) -> Result<(), BoxError> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    for file in [
        path.to_owned(),
        format!("{path}-wal"),
        format!("{path}-shm"),
    ] {
        match std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
            _ => {}
        }
    }
    Ok(())
}

pub(crate) fn open_db(path: &str) -> Result<Connection, BoxError> {
    if let Some(dir) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(dir)?;
    }
    if path != ":memory:" {
        owner_only(path)?;
    }
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS sessions (
             id         TEXT PRIMARY KEY,
             name       TEXT NOT NULL,
             position   INTEGER NOT NULL,
             cwd        TEXT,
             scrollback BLOB NOT NULL DEFAULT x'',
             updated_at INTEGER NOT NULL DEFAULT (unixepoch())
         );
         -- UI preferences (theme, font, ...) as one JSON object; the page owns its shape.
         CREATE TABLE IF NOT EXISTS settings (
             id    INTEGER PRIMARY KEY CHECK (id = 1),
             value TEXT NOT NULL
         );",
    )?;
    crate::board::migrate(&conn)?;
    Ok(conn)
}

/// Write scrollback and cwd of every session whose output changed.
///
/// Each session's scrollback is copied out under its `output` lock alone, and
/// the database is locked only for that session's write: never while waiting
/// on a busy shell's output, nor across every session's copy, so hooks,
/// status changes and the session list don't queue behind a flush.
///
/// Whole flushes run one at a time: the shutdown flush waits for a periodic
/// one still holding a copy it has yet to write.
pub(crate) fn flush(state: &AppState) {
    static FLUSHING: Mutex<()> = Mutex::new(());
    let _turn = FLUSHING.lock().unwrap_or_else(|e| e.into_inner());
    let live: Vec<(String, Arc<Session>)> = state
        .live
        .lock()
        .unwrap()
        .iter()
        .map(|(id, s)| (id.clone(), s.clone()))
        .collect();
    for (id, session) in live {
        if let Some(scrollback) = take_dirty(&session) {
            save(state, &id, &session, scrollback);
        }
    }
}

/// A copy of the session's scrollback if it changed since the last flush,
/// taken under its `output` lock alone.
fn take_dirty(session: &Session) -> Option<Vec<u8>> {
    let mut out = session.output.lock().unwrap();
    if !out.dirty {
        return None;
    }
    out.dirty = false;
    Some(out.scrollback_bytes())
}

/// Writes one session's copied scrollback and its cwd, holding `db` for that
/// write alone. A session being restarted is skipped: `restart` flags it
/// before saving its newer screen, so this copy is stale. A failed write
/// leaves the session dirty for the next flush.
fn save(state: &AppState, id: &str, session: &Session, scrollback: Vec<u8>) {
    let cwd = session.pid.and_then(process_cwd);
    let saved = {
        let db = state.db.lock().unwrap();
        if session.restarting.load(Ordering::SeqCst) {
            return;
        }
        db.execute(
            "UPDATE sessions SET scrollback = ?1, cwd = COALESCE(?2, cwd), updated_at = unixepoch()
             WHERE id = ?3",
            params![scrollback, cwd, id],
        )
    };
    if let Err(e) = saved {
        eprintln!("failed to save session {id}: {e}");
        session.output.lock().unwrap().dirty = true;
    }
}

/// The columns `SessionInfo` is read from, in `info_row`'s order.
pub(crate) const INFO_COLUMNS: &str =
    "id, name, status, status_at, note, cwd, pinned, pending_prompt, pending_command,
     COALESCE(pending_command, resume_command), parent, mode, acp_command";

pub(super) fn info_row(r: &rusqlite::Row) -> rusqlite::Result<SessionInfo> {
    Ok(SessionInfo {
        id: r.get(0)?,
        name: r.get(1)?,
        status: r.get(2)?,
        status_at: r.get(3)?,
        note: r.get(4)?,
        cwd: r.get(5)?,
        pinned: r.get(6)?,
        pending_prompt: r.get(7)?,
        pending_command: r.get(8)?,
        agent_command: r.get(9)?,
        parent: r.get(10)?,
        mode: r.get(11)?,
        acp_command: r.get(12)?,
    })
}

/// One session as the tab strip and the board see it.
pub(crate) fn info(db: &Connection, id: &str) -> rusqlite::Result<Option<SessionInfo>> {
    use rusqlite::OptionalExtension;
    db.query_row(
        &format!("SELECT {INFO_COLUMNS} FROM sessions WHERE id = ?1"),
        params![id],
        info_row,
    )
    .optional()
}

/// What a new session starts as.
pub(crate) struct NewCard<'a> {
    pub(crate) cwd: Option<&'a str>,
    /// `None`: the next free "Terminal N".
    pub(crate) name: Option<&'a str>,
    pub(crate) status: &'a str,
    /// Typed into the shell once the card is In progress and it runs.
    pub(crate) pending: Option<&'a str>,
    /// Handed to that shell as `TABSH_PROMPT`.
    pub(crate) prompt: Option<&'a str>,
    /// The launch template `pending` was built from (`launch_line`'s input),
    /// so an edit of the prompt can prefill the card's agent.
    pub(crate) command: Option<&'a str>,
    /// The name was chosen by the user: shell titles don't replace it.
    pub(crate) pinned: bool,
    /// How its agent's conversation is reopened after a restart, with
    /// `{session}` for the id its hooks report.
    pub(crate) resume: Option<&'a str>,
    /// The agent's conversation, when tabsh chose it (`{session}` in the
    /// startup command), and the line that resumes it.
    pub(crate) agent_session: Option<&'a str>,
    pub(crate) resume_input: Option<&'a str>,
    /// The card this row is a side terminal of. None for a card.
    pub(crate) parent: Option<&'a str>,
    /// `"tui"` or `"ui"`.
    pub(crate) mode: &'a str,
    /// The provider's ACP command for a `"ui"` card, stored at create so
    /// the daemon can start (and restart) the chat without the page.
    pub(crate) acp_command: Option<&'a str>,
}

impl Default for NewCard<'_> {
    fn default() -> Self {
        NewCard {
            cwd: None,
            name: None,
            status: "backlog",
            pending: None,
            prompt: None,
            command: None,
            pinned: false,
            resume: None,
            agent_session: None,
            resume_input: None,
            parent: None,
            mode: "tui",
            acp_command: None,
        }
    }
}

/// Lowest `Terminal N` not used by `parent`'s side terminals.
pub(super) fn next_side_name(db: &Connection, parent: &str) -> rusqlite::Result<String> {
    let names: Vec<String> = db
        .prepare("SELECT name FROM sessions WHERE parent = ?1")?
        .query_map(params![parent], |r| r.get(0))?
        .collect::<Result<Vec<_>, _>>()?;
    let mut n = 1;
    let taken = |n: u32| names.iter().any(|name| name == &format!("Terminal {n}"));
    while taken(n) {
        n += 1;
    }
    Ok(format!("Terminal {n}"))
}

#[cfg(test)]
pub(crate) fn insert_session(db: &Connection, cwd: Option<&str>) -> rusqlite::Result<SessionInfo> {
    insert_card(
        db,
        &NewCard {
            cwd,
            ..Default::default()
        },
    )
}

pub(crate) fn insert_card(db: &Connection, card: &NewCard) -> rusqlite::Result<SessionInfo> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let id = format!("{nanos:x}-{:x}", COUNTER.fetch_add(1, Ordering::Relaxed));

    let name = match card.name {
        Some(n) => n.to_owned(),
        None => {
            let names: Vec<String> = db
                .prepare("SELECT name FROM sessions WHERE parent IS NULL")?
                .query_map([], |r| r.get(0))?
                .collect::<Result<Vec<_>, _>>()?;
            let n = names
                .iter()
                .filter_map(|n| n.strip_prefix("Terminal ")?.parse::<u32>().ok())
                .max()
                .unwrap_or(0)
                + 1;
            format!("Terminal {n}")
        }
    };
    let session_token = crate::auth::random_hex(32).map_err(|e| {
        rusqlite::Error::ToSqlConversionFailure(Box::new(e))
    })?;
    db.execute(
        "INSERT INTO sessions (id, name, position, cwd, status, status_at, pending_input, pending_prompt,
                                pending_command, pinned, resume_command, agent_session, resume_input, parent, mode,
                                acp_command, session_token)
         VALUES (?1, ?2, (SELECT COALESCE(MAX(position), 0) + 1 FROM sessions), ?3, ?4, unixepoch(), ?5, ?6,
                 ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        params![
            id,
            name,
            card.cwd,
            card.status,
            card.pending,
            card.prompt,
            card.command,
            card.pinned,
            card.resume,
            card.agent_session,
            card.resume_input,
            card.parent,
            card.mode,
            card.acp_command,
            session_token,
        ],
    )?;
    Ok(info(db, &id)?.expect("just inserted"))
}

/// The card that minted `token`, if any.
pub(crate) fn session_id_for_token(db: &Connection, token: &str) -> Option<String> {
    if token.len() < 32 {
        return None;
    }
    db.query_row(
        "SELECT id FROM sessions WHERE session_token = ?1",
        [token],
        |r| r.get(0),
    )
    .ok()
}

/// The card's own bearer token, minting one if an older row still lacks it.
pub(crate) fn ensure_session_token(db: &Connection, id: &str) -> rusqlite::Result<String> {
    let existing: Option<String> = db
        .query_row(
            "SELECT session_token FROM sessions WHERE id = ?1",
            [id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten()
        .filter(|t| t.len() >= 32);
    if let Some(token) = existing {
        return Ok(token);
    }
    let token = crate::auth::random_hex(32).map_err(|e| {
        rusqlite::Error::ToSqlConversionFailure(Box::new(e))
    })?;
    let updated = db.execute(
        "UPDATE sessions SET session_token = ?1
         WHERE id = ?2 AND (session_token IS NULL OR length(session_token) < 32)",
        params![token, id],
    )?;
    if updated == 1 {
        return Ok(token);
    }
    // Another starter won the race, or the card is gone.
    db.query_row(
        "SELECT session_token FROM sessions WHERE id = ?1",
        [id],
        |r| r.get(0),
    )
}

/// Sets the tab order: `ids` first, in that order, then any other sessions in
/// their old order.
pub(crate) fn reorder(db: &mut Connection, ids: &[String]) -> rusqlite::Result<()> {
    let tx = db.transaction()?;
    let old: Vec<String> = tx
        .prepare("SELECT id FROM sessions ORDER BY position")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let given = ids.iter().filter(|id| old.contains(id));
    let rest = old.iter().filter(|id| !ids.contains(id));
    for (pos, id) in given.chain(rest).enumerate() {
        tx.execute(
            "UPDATE sessions SET position = ?1 WHERE id = ?2",
            params![pos as i64 + 1, id],
        )?;
    }
    tx.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode(path: &std::path::Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    fn make_readable(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644)).unwrap();
    }

    // It holds the device tokens, like the token file beside it.
    #[test]
    fn the_database_is_readable_by_its_owner_only() {
        let path = crate::test_support::scratch().join("state.db");
        std::fs::write(&path, b"").unwrap();
        make_readable(&path);
        let conn = open_db(path.to_str().unwrap()).unwrap();
        conn.execute(
            "INSERT INTO sessions (id, name, position) VALUES ('s', 'T', 1)",
            [],
        )
        .unwrap();
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&path.with_file_name("state.db-wal")), 0o600);
    }

    #[test]
    fn its_left_over_journal_files_are_owner_only_too() {
        let path = crate::test_support::scratch().join("state.db");
        drop(open_db(path.to_str().unwrap()).unwrap());
        let wal = path.with_file_name("state.db-wal");
        let shm = path.with_file_name("state.db-shm");
        for p in [&path, &wal, &shm] {
            if !p.exists() {
                std::fs::write(p, b"").unwrap();
            }
            make_readable(p);
        }
        let _conn = open_db(path.to_str().unwrap()).unwrap();
        for p in [&path, &wal, &shm] {
            assert_eq!(mode(p), 0o600, "{}", p.display());
        }
    }

    fn saved_scrollback(st: &AppState, id: &str) -> Vec<u8> {
        st.db
            .lock()
            .unwrap()
            .query_row(
                "SELECT scrollback FROM sessions WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .unwrap()
    }

    // A busy shell's reader holds its `output` while it appends: the flusher
    // waiting on it must not hold the database, or every hook, status change
    // and session list waits too.
    #[test]
    fn flush_never_holds_the_db_while_waiting_on_a_sessions_output() {
        let st = crate::test_support::test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let session = super::super::pty::get_or_spawn(&st, &id).unwrap().unwrap();

        let mut out = session.output.lock().unwrap();
        out.scrollback = vec![b'x'; super::super::SCROLLBACK_BYTES].into();
        out.dirty = true;
        let flusher = {
            let st = st.clone();
            std::thread::spawn(move || flush(&st))
        };
        std::thread::sleep(std::time::Duration::from_millis(100));

        // A hook's status change and a session list, while the output is held.
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
        let db_free = loop {
            if let Ok(db) = st.db.try_lock() {
                db.execute(
                    "UPDATE sessions SET status = 'needs_input' WHERE id = ?1",
                    params![id],
                )
                .unwrap();
                assert!(info(&db, &id).unwrap().is_some());
                break true;
            }
            if std::time::Instant::now() > deadline {
                break false;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        };
        drop(out);
        flusher.join().unwrap();
        let saved = saved_scrollback(&st, &id);
        let _ = session.killer.lock().unwrap().kill();

        assert!(db_free, "flush held the db while waiting on output");
        assert!(saved.len() >= 1000 && saved[..1000].iter().all(|&b| b == b'x'));
    }

    /// A live session whose screen is `scrollback` alone and dirty, once its
    /// shell has gone quiet (no prompt still on its way to dirty it again).
    fn spawn_dirty(st: &AppState, scrollback: &[u8]) -> (String, Arc<Session>) {
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let session = super::super::pty::get_or_spawn(st, &id).unwrap().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            session.output.lock().unwrap().dirty = false;
            std::thread::sleep(std::time::Duration::from_millis(400));
            if !session.output.lock().unwrap().dirty {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "shell never went quiet"
            );
        }
        let mut out = session.output.lock().unwrap();
        out.scrollback = scrollback.to_vec().into();
        out.dirty = true;
        drop(out);
        (id, session)
    }

    /// Ends a test's shell, keeping its row (as a restart does).
    fn end(session: &Session) {
        session.restarting.store(true, Ordering::SeqCst);
        let _ = session.killer.lock().unwrap().kill();
    }

    fn pause() {
        std::thread::sleep(std::time::Duration::from_millis(150));
    }

    // The shutdown flush must not finish while the periodic one still holds
    // a copy it has yet to write: the daemon exits right after it.
    #[test]
    fn a_flush_waits_for_the_one_still_writing() {
        let st = crate::test_support::test_state();
        let (id, session) = spawn_dirty(&st, b"latest screen");

        let db = st.db.lock().unwrap();
        let periodic = {
            let st = st.clone();
            std::thread::spawn(move || flush(&st))
        };
        pause(); // it has copied the screen and waits on the db
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let shutdown = {
            let (st, done) = (st.clone(), done.clone());
            std::thread::spawn(move || {
                flush(&st);
                done.store(true, Ordering::SeqCst);
            })
        };
        pause();
        let finished_early = done.load(Ordering::SeqCst);
        drop(db);
        periodic.join().unwrap();
        shutdown.join().unwrap();
        let saved = saved_scrollback(&st, &id);
        end(&session);

        assert!(
            !finished_early,
            "the second flush returned before the first wrote"
        );
        assert!(saved.starts_with(b"latest screen"));
    }

    // A flush that copied the screen before a restart must not overwrite the
    // newer screen the restart saved: the replacement shell replays it.
    #[test]
    fn a_flush_copied_before_a_restart_keeps_the_restarts_screen() {
        let st = crate::test_support::test_state();
        let (id, session) = spawn_dirty(&st, b"older screen");
        let stale = take_dirty(&session).unwrap();
        session.output.lock().unwrap().scrollback = b"newer screen".to_vec().into();
        super::super::restart(&st, &id);
        save(&st, &id, &session, stale);
        assert!(
            saved_scrollback(&st, &id).starts_with(b"newer screen"),
            "a stale flush overwrote the restart's save"
        );

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !session.output.lock().unwrap().exited {
            assert!(std::time::Instant::now() < deadline, "shell did not exit");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let again = super::super::pty::get_or_spawn(&st, &id).unwrap().unwrap();
        let replay: Vec<u8> = again
            .output
            .lock()
            .unwrap()
            .scrollback
            .iter()
            .copied()
            .collect();
        end(&again);
        assert!(replay.starts_with(b"newer screen"));
    }

    // A write that fails leaves the screen dirty, so the next flush retries.
    #[test]
    fn a_failed_write_is_retried_by_the_next_flush() {
        let st = crate::test_support::test_state();
        let (id, session) = spawn_dirty(&st, b"unsaved screen");
        st.db
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER no_save BEFORE UPDATE OF scrollback ON sessions
                 BEGIN SELECT RAISE(FAIL, 'disk full'); END;",
            )
            .unwrap();
        flush(&st);
        let dirty = session.output.lock().unwrap().dirty;
        st.db
            .lock()
            .unwrap()
            .execute_batch("DROP TRIGGER no_save;")
            .unwrap();
        flush(&st);
        let saved = saved_scrollback(&st, &id);
        end(&session);
        assert!(dirty, "a failed write must leave the screen dirty");
        assert!(saved.starts_with(b"unsaved screen"));
    }

    // What a flush saves is what the shell started after a daemon restart
    // replays.
    #[test]
    fn flushed_scrollback_is_restored_by_the_next_shell() {
        let st = crate::test_support::test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let first = super::super::pty::get_or_spawn(&st, &id).unwrap().unwrap();
        {
            let mut out = first.output.lock().unwrap();
            out.scrollback = b"hello from before".to_vec().into();
            out.dirty = true;
        }
        flush(&st);
        assert!(saved_scrollback(&st, &id).starts_with(b"hello from before"));

        // The shell goes, keeping its session (as a restart does).
        first.restarting.store(true, Ordering::SeqCst);
        let _ = first.killer.lock().unwrap().kill();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while st.live.lock().unwrap().contains_key(&id) {
            assert!(std::time::Instant::now() < deadline, "shell did not exit");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let again = super::super::pty::get_or_spawn(&st, &id).unwrap().unwrap();
        let restored: Vec<u8> = again
            .output
            .lock()
            .unwrap()
            .scrollback
            .iter()
            .copied()
            .collect();
        again.restarting.store(true, Ordering::SeqCst);
        let _ = again.killer.lock().unwrap().kill();
        assert!(restored.starts_with(b"hello from before"));
    }

    #[test]
    fn new_session_can_start_in_a_directory() {
        let db = open_db(":memory:").unwrap();
        let a = insert_session(&db, None).unwrap();
        let b = insert_session(&db, Some("/tmp")).unwrap();
        assert_eq!(a.name, "Terminal 1");
        assert_eq!(b.name, "Terminal 2");
        let cwd: Option<String> = db
            .query_row(
                "SELECT cwd FROM sessions WHERE id = ?1",
                params![b.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cwd.as_deref(), Some("/tmp"));
    }

    #[test]
    fn reorder_puts_given_ids_first_and_keeps_the_rest_in_order() {
        let mut db = open_db(":memory:").unwrap();
        let [a, b, c, d] = [(); 4].map(|_| insert_session(&db, None).unwrap().id);
        reorder(&mut db, &[c.clone(), "nope".into(), a.clone()]).unwrap();
        let order: Vec<String> = db
            .prepare("SELECT id FROM sessions ORDER BY position")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(order, [c, a, b, d]);
    }

    #[test]
    fn new_sessions_are_backlog_cards() {
        let db = open_db(":memory:").unwrap();
        let a = insert_session(&db, Some("/tmp")).unwrap();
        assert_eq!(a.status, "backlog");
        assert!(a.status_at > 1_700_000_000, "status_at is now, not 0");
        assert_eq!(a.note, None);
        assert_eq!(a.cwd.as_deref(), Some("/tmp"));
    }

    #[test]
    fn a_card_can_start_named_with_a_status_and_pending_input() {
        let db = open_db(":memory:").unwrap();
        let c = insert_card(
            &db,
            &NewCard {
                cwd: None,
                name: Some("Fix login"),
                status: "in_progress",
                pending: Some("claude 'x'\r"),
                prompt: None,
                command: None,
                pinned: false,
                resume: None,
                agent_session: None,
                resume_input: None,
                parent: None,
                mode: "tui",
                acp_command: None,
            },
        )
        .unwrap();
        assert_eq!(
            (c.name.as_str(), c.status.as_str()),
            ("Fix login", "in_progress")
        );
        let pending: Option<String> = db
            .query_row(
                "SELECT pending_input FROM sessions WHERE id = ?1",
                params![c.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(pending.as_deref(), Some("claude 'x'\r"));
        assert_eq!(info(&db, &c.id).unwrap().unwrap().name, "Fix login");
        assert!(info(&db, "missing").unwrap().is_none());
    }

    #[test]
    fn an_old_database_gains_the_card_columns() {
        let dir = crate::test_support::scratch();
        let path = dir.join("state.db");
        let path = path.to_str().unwrap();
        {
            let old = Connection::open(path).unwrap();
            old.execute_batch(
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL,
                 cwd TEXT, scrollback BLOB NOT NULL DEFAULT x'', updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
                 INSERT INTO sessions (id, name, position) VALUES ('old', 'Terminal 1', 1);",
            )
            .unwrap();
        }
        let db = open_db(path).unwrap();
        let s = info(&db, "old").unwrap().unwrap();
        assert_eq!(s.status, "backlog");
        assert!(s.status_at > 1_700_000_000);
        assert_eq!(s.parent, None);
        // Opening twice is fine (migration is idempotent).
        drop(db);
        open_db(path).unwrap();
    }
}
