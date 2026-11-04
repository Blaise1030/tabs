//! Live updates for the explorer: `GET /api/files/watch` is a WebSocket that
//! tells the page which paths under a tab's project root were added or
//! removed, so its tree follows the disk.
//!
//! One watcher per root serves every socket on it and is dropped with the
//! last one. Its events are coalesced over `WINDOW`, then each changed path is
//! checked on disk, so a burst (a build, `git checkout`) is one message and
//! only what is still true is sent. Messages are `{"add":[…],"remove":[…]}`
//! with root-relative paths, directories ending in `/` (a removed path's kind
//! is gone with it, so removes carry no `/`), or `{"reset":true}`, after
//! which the page re-fetches the listing.
//!
//! A socket follows its tab's shell: every `ROOT_CHECK` it looks at the
//! session's directory, and when the project root differs from the one it
//! watches it sends `{"root":"/abs/new/root"}`, moves to that root's watcher
//! and lets the old one go. A root with too many files has no watcher; the
//! socket stays open and resumes when the root changes again. A session that
//! is gone ends the socket.

use super::{
    TreeQuery,
    resolve::session_base_dir,
    tree::{TREE_LIMIT_PATHS, list_tree, tree_path, tree_root, visible_names, walker},
};
use crate::{AppState, sessions};
use axum::{
    extract::{
        Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
};
use futures_util::{SinkExt, StreamExt};
use notify::{
    Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher as _,
    event::{Flag, ModifyKind},
};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    ffi::OsString,
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
    time::Duration,
};
use tokio::sync::{broadcast, mpsc};

/// Events are gathered this long before the disk is checked.
const WINDOW: Duration = Duration::from_millis(100);
/// A batch of more paths than this is sent as a reset.
const RESET_ABOVE: usize = 1_000;
const RESET: &str = r#"{"reset":true}"#;
/// How often a socket looks at where its tab's shell is.
const ROOT_CHECK: Duration = Duration::from_secs(1);

/// What a notify event said happened to a path.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Seen {
    Created,
    Removed,
    /// Renamed, or some other change to the path itself.
    Changed,
    /// Only the file's content or metadata: nothing for a tree, except in a
    /// `.gitignore`.
    Content,
}

#[derive(Debug, PartialEq)]
enum Raw {
    Path(PathBuf, Seen),
    /// The backend lost events, or says to look again.
    Rescan,
}

/// What the page is told for one window.
#[derive(Debug, PartialEq)]
enum Batch {
    Reset,
    Changes {
        add: Vec<String>,
        remove: Vec<String>,
    },
}

impl Batch {
    /// The socket message, or `None` when nothing changed.
    fn message(&self) -> Option<String> {
        match self {
            Batch::Reset => Some(RESET.into()),
            Batch::Changes { add, remove } if add.is_empty() && remove.is_empty() => None,
            Batch::Changes { add, remove } => {
                Some(serde_json::json!({ "add": add, "remove": remove }).to_string())
            }
        }
    }
}

/// What a create event proves. FSEvents (macOS) reports the flags a path has
/// gathered, not what just happened: a file made earlier can show a create
/// when it is renamed or removed. There a create says nothing, so a path that
/// turns out gone is removed, not forgotten.
const CREATE: Seen = if cfg!(target_os = "macos") {
    Seen::Changed
} else {
    Seen::Created
};

/// Turns notify's answer into what the coalescer needs.
fn raws(res: notify::Result<Event>) -> Vec<Raw> {
    let Ok(event) = res else {
        return vec![Raw::Rescan];
    };
    if event.flag() == Some(Flag::Rescan) {
        return vec![Raw::Rescan];
    }
    let seen = match event.kind {
        EventKind::Access(_) => return Vec::new(),
        EventKind::Create(_) => CREATE,
        EventKind::Remove(_) => Seen::Removed,
        EventKind::Modify(ModifyKind::Data(_) | ModifyKind::Metadata(_)) => Seen::Content,
        EventKind::Modify(_) | EventKind::Any | EventKind::Other => Seen::Changed,
    };
    event
        .paths
        .into_iter()
        .map(|p| Raw::Path(p, seen))
        .collect()
}

/// What the coalescer asks of the disk.
trait Disk {
    /// Whether `rel` exists, and whether it is a directory.
    fn is_dir(&mut self, rel: &Path) -> Option<bool>;
    /// Whether the listing shows `rel`. For a path that is gone, whether it
    /// could have been shown (nothing above it hides it).
    fn listed(&mut self, rel: &Path) -> bool;
    /// The listed paths under the directory `rel`, at most `limit`.
    fn walk(&mut self, rel: &Path, limit: usize) -> Vec<String>;
}

/// Decides what to tell the page about the events of one window. The disk is
/// looked at after the window, so create-then-delete is nothing and a rename
/// is a remove and an add.
fn coalesce(events: &[Raw], root: &Path, disk: &mut impl Disk) -> Batch {
    // Per changed path: the first thing that structurally happened to it.
    let mut changed: BTreeMap<PathBuf, Option<Seen>> = BTreeMap::new();
    for event in events {
        let Raw::Path(path, seen) = event else {
            return Batch::Reset;
        };
        let Ok(rel) = path.strip_prefix(root) else {
            continue;
        };
        if rel.as_os_str().is_empty() || rel.components().any(|c| c.as_os_str() == ".git") {
            continue;
        }
        // Which paths are ignored may have changed.
        if rel.file_name().is_some_and(|n| n == ".gitignore") {
            return Batch::Reset;
        }
        let first = changed.entry(rel.to_path_buf()).or_insert(None);
        if first.is_none() && *seen != Seen::Content {
            *first = Some(*seen);
        }
    }

    let mut add = BTreeSet::new();
    let mut remove = BTreeSet::new();
    for (rel, first) in changed {
        let Some(first) = first else { continue };
        match disk.is_dir(&rel) {
            Some(is_dir) => {
                if !disk.listed(&rel) {
                    continue;
                }
                add.insert(tree_path(&rel, is_dir));
                if is_dir {
                    add.extend(disk.walk(&rel, RESET_ABOVE + 1));
                }
            }
            // Created and gone within the window: the page never knew it.
            None if first == Seen::Created => {}
            None => {
                if disk.listed(&rel) {
                    remove.insert(tree_path(&rel, false));
                }
            }
        }
        if add.len() + remove.len() > RESET_ABOVE {
            return Batch::Reset;
        }
    }
    Batch::Changes {
        add: add.into_iter().collect(),
        remove: remove.into_iter().collect(),
    }
}

/// The real disk, seen through the same walk as the listing.
struct FsDisk {
    root: PathBuf,
    /// Listed names per directory, read once per window.
    names: HashMap<PathBuf, HashSet<OsString>>,
}

impl Disk for FsDisk {
    fn is_dir(&mut self, rel: &Path) -> Option<bool> {
        std::fs::symlink_metadata(self.root.join(rel))
            .ok()
            .map(|m| m.is_dir())
    }

    fn listed(&mut self, rel: &Path) -> bool {
        let mut dir = self.root.clone();
        for part in rel.components() {
            let Component::Normal(name) = part else {
                return false;
            };
            let names = self
                .names
                .entry(dir.clone())
                .or_insert_with(|| visible_names(&dir));
            if !names.contains(name) {
                // Hidden by an ignore rule if it's there; if it's gone, the
                // rules above it never hid it.
                return std::fs::symlink_metadata(dir.join(name)).is_err();
            }
            dir.push(name);
        }
        true
    }

    fn walk(&mut self, rel: &Path, limit: usize) -> Vec<String> {
        walker(&self.root.join(rel))
            .build()
            .flatten()
            .filter(|entry| entry.depth() > 0)
            .take(limit)
            .filter_map(|entry| {
                let rel = entry.path().strip_prefix(&self.root).ok()?;
                Some(tree_path(
                    rel,
                    entry.file_type().is_some_and(|t| t.is_dir()),
                ))
            })
            .collect()
    }
}

/// A live watch of one root, shared by its sockets. Dropping it stops the
/// backend and the coalescing task.
pub(super) struct Watcher {
    changes: broadcast::Sender<Arc<str>>,
    _backend: RecommendedWatcher,
    task: tokio::task::AbortHandle,
}

impl Drop for Watcher {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Watcher {
    fn start(root: PathBuf) -> notify::Result<Watcher> {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel();
        let mut backend = notify::recommended_watcher(move |res| {
            for raw in raws(res) {
                let _ = raw_tx.send(raw);
            }
        })?;
        backend.watch(&root, RecursiveMode::Recursive)?;
        let (changes, _) = broadcast::channel(16);
        let task = tokio::spawn(coalescer(root, raw_rx, changes.clone())).abort_handle();
        Ok(Watcher {
            changes,
            _backend: backend,
            task,
        })
    }

    fn subscribe(&self) -> broadcast::Receiver<Arc<str>> {
        self.changes.subscribe()
    }
}

/// Gathers a window of events, then sends what changed.
async fn coalescer(
    root: PathBuf,
    mut raw: mpsc::UnboundedReceiver<Raw>,
    out: broadcast::Sender<Arc<str>>,
) {
    while let Some(first) = raw.recv().await {
        let mut events = vec![first];
        let window = tokio::time::sleep(WINDOW);
        tokio::pin!(window);
        loop {
            tokio::select! {
                () = &mut window => break,
                event = raw.recv() => match event {
                    Some(event) => events.push(event),
                    None => return,
                },
            }
        }
        let at = root.clone();
        let batch = tokio::task::spawn_blocking(move || {
            let mut disk = FsDisk {
                root: at.clone(),
                names: HashMap::new(),
            };
            coalesce(&events, &at, &mut disk)
        })
        .await;
        if let Some(message) = batch.ok().and_then(|b| b.message()) {
            let _ = out.send(message.into());
        }
    }
}

#[derive(Debug, PartialEq)]
enum WatchError {
    /// More files than the explorer lists: there is no tree to keep current.
    Truncated,
    Backend(String),
}

/// The live watchers, by root.
#[derive(Default)]
struct Registry(Mutex<HashMap<PathBuf, Weak<Watcher>>>);

impl Registry {
    fn live(&self, root: &Path) -> Option<Arc<Watcher>> {
        self.0.lock().unwrap().get(root).and_then(Weak::upgrade)
    }

    /// The watcher for `root`, started if no socket has one. The registry
    /// holds only a `Weak`, so the watcher ends with its last socket.
    async fn acquire(&self, root: PathBuf, limit: usize) -> Result<Arc<Watcher>, WatchError> {
        // The backends report real paths; the listing's root may be a symlink.
        let root =
            tokio::task::spawn_blocking(move || std::fs::canonicalize(&root).unwrap_or(root))
                .await
                .map_err(|e| WatchError::Backend(e.to_string()))?;
        // Walking the root to see if it is too big is only for a watcher
        // that is about to start.
        if let Some(watcher) = self.live(&root) {
            return Ok(watcher);
        }
        let at = root.clone();
        let truncated = tokio::task::spawn_blocking(move || list_tree(&at, limit).truncated)
            .await
            .map_err(|e| WatchError::Backend(e.to_string()))?;
        // Another socket may have started one meanwhile: look again and
        // insert under the same lock.
        let mut live = self.0.lock().unwrap();
        if let Some(watcher) = live.get(&root).and_then(Weak::upgrade) {
            return Ok(watcher);
        }
        if truncated {
            return Err(WatchError::Truncated);
        }
        let watcher =
            Arc::new(Watcher::start(root.clone()).map_err(|e| WatchError::Backend(e.to_string()))?);
        live.retain(|_, w| w.strong_count() > 0);
        live.insert(root, Arc::downgrade(&watcher));
        Ok(watcher)
    }
}

fn registry() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(Registry::default)
}

/// Upgrades to the socket that tells the page what changed in the tab's
/// project. The token is in the query (`guard` has checked it), as for the
/// terminal sockets.
pub(super) async fn watch_handler(
    ws: WebSocketUpgrade,
    Query(q): Query<TreeQuery>,
    State(st): State<AppState>,
) -> Response {
    let session = q.session.unwrap_or_default();
    let (cwd_st, id) = (st.clone(), session.clone());
    let root = tokio::task::spawn_blocking(move || tree_root(&session_base_dir(&cwd_st, &id)))
        .await
        .unwrap_or_default();
    let root = tokio::task::spawn_blocking(move || std::fs::canonicalize(&root).unwrap_or(root))
        .await
        .unwrap_or_default();
    let mut follow = Follow::at(root.clone());
    match registry().acquire(root, TREE_LIMIT_PATHS).await {
        Ok(watcher) => follow.watch(watcher),
        // The socket stays: the tab may move to a root that can be watched.
        Err(WatchError::Truncated) => {}
        Err(WatchError::Backend(e)) => {
            eprintln!("failed to watch files: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    ws.on_upgrade(move |socket| relay(socket, st, session, follow))
}

/// What a socket follows: the project root of its tab, and the watcher on it
/// (none while it has too many files).
struct Follow {
    root: PathBuf,
    watcher: Option<(Arc<Watcher>, broadcast::Receiver<Arc<str>>)>,
}

impl Follow {
    fn at(root: PathBuf) -> Follow {
        Follow {
            root,
            watcher: None,
        }
    }

    fn watch(&mut self, watcher: Arc<Watcher>) {
        let changes = watcher.subscribe();
        self.watcher = Some((watcher, changes));
    }

    /// The next message from the watcher; never, while there is none.
    async fn next_change(&mut self) -> Result<Arc<str>, broadcast::error::RecvError> {
        match &mut self.watcher {
            Some((_, changes)) => changes.recv().await,
            None => std::future::pending().await,
        }
    }
}

/// What the tab's shell did to the root, as far as the socket can tell.
#[derive(Debug, PartialEq)]
enum Look {
    /// The session no longer exists.
    Gone,
    Same,
    Moved(PathBuf),
}

/// Compares the project root of the session's directory (`None`: no such
/// session) with the root being followed. Blocking: it probes the disk.
fn look(followed: &Path, cwd: Option<PathBuf>) -> Look {
    let Some(cwd) = cwd else { return Look::Gone };
    let root = tree_root(&cwd);
    let root = std::fs::canonicalize(&root).unwrap_or(root);
    if root == followed {
        Look::Same
    } else {
        Look::Moved(root)
    }
}

/// Moves the socket to `root`: the old watcher is let go first, so one that
/// nobody else uses ends. A root that can't be watched leaves the socket
/// without one.
async fn move_to(registry: &Registry, follow: &mut Follow, root: PathBuf, limit: usize) {
    follow.watcher = None;
    follow.root = root.clone();
    match registry.acquire(root, limit).await {
        Ok(watcher) => follow.watch(watcher),
        Err(WatchError::Truncated) => {}
        Err(WatchError::Backend(e)) => eprintln!("failed to watch files: {e}"),
    }
}

/// Forwards the watcher's messages, and says when the tab's root changes,
/// until the browser or the session goes away.
async fn relay(socket: WebSocket, st: AppState, session: String, mut follow: Follow) {
    let (mut sink, mut stream) = socket.split();
    let mut check = tokio::time::interval_at(tokio::time::Instant::now() + ROOT_CHECK, ROOT_CHECK);
    check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        let text = tokio::select! {
            change = follow.next_change() => match change {
                Ok(text) => text.to_string(),
                // Behind: some changes were dropped, so start over.
                Err(broadcast::error::RecvError::Lagged(_)) => RESET.to_string(),
                Err(broadcast::error::RecvError::Closed) => break,
            },
            _ = check.tick() => {
                let (st, id, followed) = (st.clone(), session.clone(), follow.root.clone());
                let seen = tokio::task::spawn_blocking(move || {
                    let cwd = sessions::exists(&st, &id).then(|| session_base_dir(&st, &id));
                    look(&followed, cwd)
                })
                .await;
                match seen {
                    Ok(Look::Moved(root)) => {
                        let text = serde_json::json!({ "root": root }).to_string();
                        move_to(registry(), &mut follow, root, TREE_LIMIT_PATHS).await;
                        text
                    }
                    Ok(Look::Same) | Err(_) => continue,
                    Ok(Look::Gone) => break,
                }
            },
            msg = stream.next() => match msg {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => continue,
            },
        };
        if sink.send(Message::Text(text.into())).await.is_err() {
            break;
        }
    }
    let _ = sink.close().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        state::router,
        test_support::{scratch, test_state},
    };
    use futures_util::StreamExt;
    use notify::event::{CreateKind, DataChange, RemoveKind, RenameMode};
    use tokio_tungstenite::tungstenite::{Error as WsError, client::IntoClientRequest};

    const ROOT: &str = "/proj";

    /// A disk held in a map: path → is a directory.
    #[derive(Default)]
    struct Fake {
        present: HashMap<PathBuf, bool>,
        hidden: Vec<PathBuf>,
        children: HashMap<PathBuf, Vec<String>>,
    }

    impl Fake {
        fn with(mut self, rel: &str, is_dir: bool) -> Self {
            self.present.insert(rel.into(), is_dir);
            self
        }
    }

    impl Disk for Fake {
        fn is_dir(&mut self, rel: &Path) -> Option<bool> {
            self.present.get(rel).copied()
        }
        fn listed(&mut self, rel: &Path) -> bool {
            !self.hidden.iter().any(|h| rel.starts_with(h))
        }
        fn walk(&mut self, rel: &Path, limit: usize) -> Vec<String> {
            let mut all = self.children.get(rel).cloned().unwrap_or_default();
            all.truncate(limit);
            all
        }
    }

    fn at(rel: &str, seen: Seen) -> Raw {
        Raw::Path(Path::new(ROOT).join(rel), seen)
    }

    fn run(events: &[Raw], disk: &mut Fake) -> Batch {
        coalesce(events, Path::new(ROOT), disk)
    }

    fn changes(add: &[&str], remove: &[&str]) -> Batch {
        Batch::Changes {
            add: add.iter().map(|s| s.to_string()).collect(),
            remove: remove.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn a_burst_is_one_batch_with_each_path_once() {
        let mut disk = Fake::default().with("a.txt", false).with("b.txt", false);
        let events = [
            at("a.txt", Seen::Created),
            at("b.txt", Seen::Created),
            at("a.txt", Seen::Content),
            at("a.txt", Seen::Content),
        ];
        assert_eq!(run(&events, &mut disk), changes(&["a.txt", "b.txt"], &[]));
    }

    #[test]
    fn created_then_deleted_in_one_window_is_nothing() {
        let mut disk = Fake::default();
        let events = [at("tmp.txt", Seen::Created), at("tmp.txt", Seen::Removed)];
        let batch = run(&events, &mut disk);
        assert_eq!(batch, changes(&[], &[]));
        assert_eq!(batch.message(), None);
    }

    #[test]
    fn a_rename_is_a_remove_and_an_add() {
        let mut disk = Fake::default().with("src/renamed.rs", false);
        let events = [
            at("src/new.rs", Seen::Changed),
            at("src/renamed.rs", Seen::Changed),
        ];
        assert_eq!(
            run(&events, &mut disk),
            changes(&["src/renamed.rs"], &["src/new.rs"])
        );
    }

    #[test]
    fn a_deleted_path_is_removed_without_a_slash() {
        let mut disk = Fake::default();
        let events = [at("lib", Seen::Removed)];
        assert_eq!(run(&events, &mut disk), changes(&[], &["lib"]));
    }

    #[test]
    fn a_new_directory_brings_its_walked_children() {
        let mut disk = Fake::default().with("lib", true).with("lib/deep", true);
        disk.children.insert(
            "lib".into(),
            vec!["lib/deep/".into(), "lib/deep/x.ts".into()],
        );
        let events = [at("lib", Seen::Created), at("lib/deep", Seen::Created)];
        assert_eq!(
            run(&events, &mut disk),
            changes(&["lib/", "lib/deep/", "lib/deep/x.ts"], &[])
        );
    }

    #[test]
    fn ignored_and_dot_git_paths_are_dropped() {
        let mut disk = Fake::default()
            .with("target/ignored.txt", false)
            .with(".git/index", false)
            .with("keep.txt", false);
        disk.hidden.push("target".into());
        let events = [
            at("target/ignored.txt", Seen::Created),
            at(".git/index", Seen::Changed),
            at("keep.txt", Seen::Created),
            // Gone, but under a hidden directory: never in the tree.
            at("target/old.txt", Seen::Removed),
        ];
        assert_eq!(run(&events, &mut disk), changes(&["keep.txt"], &[]));
    }

    #[test]
    fn content_changes_say_nothing() {
        let mut disk = Fake::default().with("a.txt", false);
        assert_eq!(
            run(&[at("a.txt", Seen::Content)], &mut disk),
            changes(&[], &[])
        );
    }

    #[test]
    fn more_than_a_thousand_paths_is_a_reset() {
        let mut disk = Fake::default();
        let mut events = Vec::new();
        for i in 0..=RESET_ABOVE {
            let name = format!("f{i}");
            disk.present.insert(name.clone().into(), false);
            events.push(at(&name, Seen::Created));
        }
        assert_eq!(run(&events, &mut disk), Batch::Reset);
        events.pop();
        assert!(matches!(run(&events, &mut disk), Batch::Changes { .. }));
    }

    #[test]
    fn a_new_directory_with_too_many_children_is_a_reset() {
        let mut disk = Fake::default().with("big", true);
        disk.children.insert(
            "big".into(),
            (0..=RESET_ABOVE).map(|i| format!("big/{i}")).collect(),
        );
        assert_eq!(run(&[at("big", Seen::Created)], &mut disk), Batch::Reset);
    }

    #[test]
    fn a_gitignore_change_is_a_reset_even_when_only_its_content_changed() {
        let mut disk = Fake::default().with(".gitignore", false);
        assert_eq!(
            run(&[at(".gitignore", Seen::Content)], &mut disk),
            Batch::Reset
        );
        assert_eq!(
            run(&[at("sub/.gitignore", Seen::Created)], &mut disk),
            Batch::Reset
        );
    }

    #[test]
    fn a_rescan_is_a_reset() {
        let mut disk = Fake::default();
        let events = [at("a", Seen::Created), Raw::Rescan];
        assert_eq!(run(&events, &mut disk), Batch::Reset);
    }

    #[test]
    fn the_backends_rescan_flag_and_errors_become_rescans() {
        let flagged = Event::new(EventKind::Other).set_flag(Flag::Rescan);
        assert_eq!(raws(Ok(flagged)), [Raw::Rescan]);
        assert_eq!(raws(Err(notify::Error::generic("overflow"))), [Raw::Rescan]);
    }

    #[test]
    fn raws_keeps_what_a_tree_cares_about() {
        let path = PathBuf::from("/proj/a");
        let event = |kind| Event::new(kind).add_path(path.clone());
        let kinds = |kind| raws(Ok(event(kind)));
        assert_eq!(
            kinds(EventKind::Create(CreateKind::File)),
            [Raw::Path(path.clone(), CREATE)]
        );
        assert_eq!(
            kinds(EventKind::Remove(RemoveKind::File)),
            [Raw::Path(path.clone(), Seen::Removed)]
        );
        assert_eq!(
            kinds(EventKind::Modify(ModifyKind::Name(RenameMode::From))),
            [Raw::Path(path.clone(), Seen::Changed)]
        );
        assert_eq!(
            kinds(EventKind::Modify(ModifyKind::Data(DataChange::Any))),
            [Raw::Path(path.clone(), Seen::Content)]
        );
        assert!(kinds(EventKind::Access(notify::event::AccessKind::Any)).is_empty());
    }

    #[test]
    fn the_real_disk_hides_what_the_listing_hides() {
        let dir = scratch();
        std::fs::write(dir.join(".gitignore"), "target/\n*.log\n").unwrap();
        for rel in ["target/junk.txt", "src/main.rs", "src/run.log", ".git/HEAD"] {
            std::fs::create_dir_all(dir.join(rel).parent().unwrap()).unwrap();
            std::fs::write(dir.join(rel), "").unwrap();
        }
        let mut disk = FsDisk {
            root: dir.clone(),
            names: HashMap::new(),
        };
        let mut listed = |rel: &str| disk.listed(Path::new(rel));
        assert!(listed("src/main.rs"));
        assert!(listed(".gitignore"));
        assert!(!listed("target"));
        assert!(!listed("target/junk.txt"));
        assert!(!listed("src/run.log"));
        assert!(!listed(".git"));
        // Gone, with nothing above hiding it.
        assert!(listed("src/deleted.rs"));
        assert!(!listed("target/deleted.rs"));
        let mut walked = disk.walk(Path::new("src"), 10);
        walked.sort_unstable();
        assert_eq!(walked, ["src/main.rs"]);
    }

    #[tokio::test]
    async fn sockets_on_one_root_share_a_watcher_dropped_with_the_last() {
        let dir = scratch();
        let registry = Registry::default();
        let first = registry.acquire(dir.clone(), 100).await.unwrap();
        let second = registry.acquire(dir.clone(), 100).await.unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        let weak = Arc::downgrade(&first);
        drop(first);
        assert!(weak.upgrade().is_some());
        drop(second);
        assert!(weak.upgrade().is_none());
        // The next socket starts a fresh one.
        let third = registry.acquire(dir, 100).await.unwrap();
        assert_eq!(Arc::strong_count(&third), 1);
    }

    #[tokio::test]
    async fn a_truncated_root_gets_no_watcher() {
        let dir = scratch();
        for name in ["a", "b", "c"] {
            std::fs::write(dir.join(name), "").unwrap();
        }
        let registry = Registry::default();
        assert_eq!(
            registry.acquire(dir.clone(), 2).await.err(),
            Some(WatchError::Truncated)
        );
        assert!(registry.acquire(dir, 3).await.is_ok());
    }

    fn project(parent: &Path, name: &str) -> PathBuf {
        let dir = std::fs::canonicalize(parent).unwrap().join(name);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        dir
    }

    #[test]
    fn look_reports_a_root_only_when_it_differs() {
        let dir = scratch();
        let (alpha, beta) = (project(&dir, "alpha"), project(&dir, "beta"));
        std::fs::create_dir_all(alpha.join("sub/deeper")).unwrap();
        // Anywhere inside the followed project is the same root.
        assert_eq!(look(&alpha, Some(alpha.clone())), Look::Same);
        assert_eq!(look(&alpha, Some(alpha.join("sub/deeper"))), Look::Same);
        assert_eq!(look(&alpha, Some(beta.clone())), Look::Moved(beta));
        // Out of any repo, the directory itself is the root.
        let loose = std::fs::canonicalize(scratch()).unwrap();
        assert_eq!(look(&alpha, Some(loose.clone())), Look::Moved(loose));
        assert_eq!(look(&alpha, None), Look::Gone);
    }

    #[cfg(unix)]
    #[test]
    fn look_compares_real_paths() {
        let dir = scratch();
        let alpha = project(&dir, "alpha");
        let link = std::fs::canonicalize(&dir).unwrap().join("link");
        std::os::unix::fs::symlink(&alpha, &link).unwrap();
        assert_eq!(look(&alpha, Some(link)), Look::Same);
    }

    #[tokio::test]
    async fn moving_swaps_watchers_and_releases_the_old_one() {
        let dir = scratch();
        let (alpha, beta) = (project(&dir, "alpha"), project(&dir, "beta"));
        let registry = Registry::default();
        let mut follow = Follow::at(alpha.clone());
        follow.watch(registry.acquire(alpha.clone(), 100).await.unwrap());
        let old = Arc::downgrade(&follow.watcher.as_ref().unwrap().0);
        move_to(&registry, &mut follow, beta.clone(), 100).await;
        assert_eq!(follow.root, beta);
        assert!(old.upgrade().is_none(), "the old watcher is still running");
        let new = follow.watcher.as_ref().unwrap().0.clone();
        assert!(Arc::ptr_eq(&new, &registry.live(&beta).unwrap()));
    }

    #[tokio::test]
    async fn moving_to_a_crowded_root_leaves_no_watcher_until_it_moves_again() {
        let dir = scratch();
        let (alpha, beta) = (project(&dir, "alpha"), project(&dir, "beta"));
        for name in ["a", "b", "c"] {
            std::fs::write(beta.join(name), "").unwrap();
        }
        let registry = Registry::default();
        let mut follow = Follow::at(alpha.clone());
        follow.watch(registry.acquire(alpha.clone(), 2).await.unwrap());
        move_to(&registry, &mut follow, beta.clone(), 2).await;
        assert_eq!(follow.root, beta);
        assert!(follow.watcher.is_none());
        move_to(&registry, &mut follow, alpha, 2).await;
        assert!(follow.watcher.is_some());
    }

    #[tokio::test]
    async fn a_live_root_is_not_walked_again() {
        let dir = scratch();
        for name in ["a", "b", "c"] {
            std::fs::write(dir.join(name), "").unwrap();
        }
        let registry = Registry::default();
        let first = registry.acquire(dir.clone(), 100).await.unwrap();
        // Over the limit now, but a watcher is running: no probe, no error.
        let second = registry.acquire(dir, 2).await.unwrap();
        assert!(Arc::ptr_eq(&first, &second));
    }

    #[tokio::test]
    async fn a_real_watcher_reports_a_new_file() {
        let dir = scratch();
        let watcher = Registry::default().acquire(dir.clone(), 100).await.unwrap();
        let mut rx = watcher.subscribe();
        std::fs::write(dir.join("hello.txt"), "hi").unwrap();
        // The backends differ in how they split events across windows.
        let heard = tokio::time::timeout(Duration::from_secs(10), async {
            while let Ok(message) = rx.recv().await {
                let json: serde_json::Value = serde_json::from_str(&message).unwrap();
                if json["add"] == serde_json::json!(["hello.txt"]) {
                    return;
                }
            }
        })
        .await;
        assert!(heard.is_ok(), "no message about hello.txt");
    }

    /// Serves the router on a local port and opens the socket for a session
    /// in an empty project, with the given Origin, and the token or not.
    async fn serve_and_request(origin: Option<&str>, token: bool) -> Result<(), WsError> {
        let st = test_state();
        st.db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO sessions (id, name, position, cwd) VALUES ('s1', 'T', 1, ?1)",
                [scratch().to_str().unwrap()],
            )
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = router(st).into_make_service_with_connect_info::<std::net::SocketAddr>();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let query = if token { "&token=t0k3n" } else { "" };
        let mut req = format!("ws://{addr}/api/files/watch?session=s1{query}")
            .into_client_request()
            .unwrap();
        if let Some(origin) = origin {
            req.headers_mut().insert("Origin", origin.parse().unwrap());
        }
        let (mut socket, _) = tokio_tungstenite::connect_async(req).await?;
        // Connected: the socket stays quiet until something changes.
        let quiet = tokio::time::timeout(Duration::from_millis(200), socket.next()).await;
        assert!(quiet.is_err());
        Ok(())
    }

    async fn heard_from<S: futures_util::Stream + Unpin>(
        socket: &mut S,
    ) -> Result<Option<S::Item>, tokio::time::error::Elapsed> {
        tokio::time::timeout(Duration::from_secs(15), socket.next()).await
    }

    #[tokio::test]
    async fn the_socket_says_when_the_root_changes_and_ends_with_the_session() {
        let dir = scratch();
        let (alpha, beta) = (project(&dir, "alpha"), project(&dir, "beta"));
        let st = test_state();
        let set_cwd = |cwd: &Path| {
            st.db
                .lock()
                .unwrap()
                .execute(
                    "UPDATE sessions SET cwd = ?1 WHERE id = 's1'",
                    [cwd.to_str().unwrap()],
                )
                .unwrap();
        };
        st.db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO sessions (id, name, position, cwd) VALUES ('s1', 'T', 1, ?1)",
                [alpha.to_str().unwrap()],
            )
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = router(st.clone()).into_make_service_with_connect_info::<std::net::SocketAddr>();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let (mut socket, _) = tokio_tungstenite::connect_async(format!(
            "ws://{addr}/api/files/watch?session=s1&token=t0k3n"
        ))
        .await
        .unwrap();
        // A cd within the project says nothing; into another one, its root.
        set_cwd(&alpha.join("sub"));
        set_cwd(&beta);
        let heard = heard_from(&mut socket).await.unwrap().unwrap().unwrap();
        let json: serde_json::Value = serde_json::from_str(heard.to_text().unwrap()).unwrap();
        assert_eq!(json, serde_json::json!({ "root": beta }));
        // The session is deleted: the socket ends.
        st.db
            .lock()
            .unwrap()
            .execute("DELETE FROM sessions", [])
            .unwrap();
        loop {
            match heard_from(&mut socket)
                .await
                .expect("the socket stayed open")
            {
                None
                | Some(Err(_))
                | Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_))) => break,
                Some(Ok(_)) => {}
            }
        }
    }

    fn status(result: Result<(), WsError>) -> Option<StatusCode> {
        match result {
            Err(WsError::Http(res)) => Some(res.status()),
            _ => None,
        }
    }

    #[tokio::test]
    async fn the_socket_upgrades_with_the_token_in_the_query() {
        assert!(
            serve_and_request(Some("https://tabsh.cc"), true)
                .await
                .is_ok()
        );
        // A client that isn't a page may connect without an Origin.
        assert!(serve_and_request(None, true).await.is_ok());
    }

    #[tokio::test]
    async fn the_socket_needs_the_token_and_a_known_origin() {
        let no_token = serve_and_request(None, false).await;
        assert_eq!(status(no_token), Some(StatusCode::UNAUTHORIZED));
        let foreign = serve_and_request(Some("https://evil.example"), true).await;
        assert_eq!(status(foreign), Some(StatusCode::FORBIDDEN));
        let page_without_token = serve_and_request(Some("https://tabsh.cc"), false).await;
        assert_eq!(status(page_without_token), Some(StatusCode::UNAUTHORIZED));
    }
}
