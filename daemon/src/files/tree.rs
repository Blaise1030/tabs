//! The explorer's listing: which directory a tab's tree is rooted at, and the
//! paths under it.

use ignore::WalkBuilder;
use serde::Serialize;
use std::{
    collections::HashSet,
    ffi::OsString,
    path::{MAIN_SEPARATOR, Path, PathBuf},
};

/// More paths than this and the page is told to show a message, not a tree.
pub(super) const TREE_LIMIT_PATHS: usize = 20_000;

/// A tree's listing. Paths are relative to `root`, with `/` after directories.
/// `folders_only` marks a listing of a root too big to list whole: its
/// folders, plus the files sitting at the root (first level), so the sidebar
/// still has something to open.
#[derive(Debug, Serialize)]
pub(super) struct Tree {
    pub(super) root: String,
    pub(super) paths: Vec<String>,
    pub(super) truncated: bool,
    #[serde(rename = "foldersOnly")]
    pub(super) folders_only: bool,
}

/// How many times the path cap the sidebar's walk may look at before giving
/// up on a folders-only listing too.
pub(super) const FOLDER_SCAN_FACTOR: usize = 2;

/// The nearest ancestor of `cwd` (itself included) holding a `.git` entry (a
/// directory, or a file in a worktree), else `cwd`.
pub(super) fn tree_root(cwd: &Path) -> PathBuf {
    cwd.ancestors()
        .find(|dir| dir.join(".git").exists())
        .unwrap_or(cwd)
        .to_path_buf()
}

/// The walk behind every listing, and behind the watcher's checks, so both
/// agree on what the tree shows.
pub(super) fn walker(dir: &Path) -> WalkBuilder {
    let mut walk = WalkBuilder::new(dir);
    walk.hidden(false)
        .require_git(false)
        .filter_entry(|entry| entry.file_name() != ".git");
    walk
}

/// The names directly inside `dir` that the listing shows.
pub(super) fn visible_names(dir: &Path) -> HashSet<OsString> {
    walker(dir)
        .max_depth(Some(1))
        .build()
        .flatten()
        .filter(|entry| entry.depth() == 1)
        .map(|entry| entry.file_name().to_owned())
        .collect()
}

/// The listing's form of a path relative to `root`: `/`-separated, with a
/// `/` after directories.
pub(super) fn tree_path(rel: &Path, is_dir: bool) -> String {
    let mut path = rel.to_string_lossy().replace(MAIN_SEPARATOR, "/");
    if is_dir {
        path.push('/');
    }
    path
}

/// Lists everything under `root` that git wouldn't ignore (`.gitignore` is
/// honoured even outside a repo), dotfiles included, `.git/` never. Past
/// `limit` paths it stops and returns none, so the page never shows a partial
/// tree.
pub(super) fn list_tree(root: &Path, limit: usize) -> Tree {
    let walk = walker(root).build();
    let mut paths = Vec::new();
    for entry in walk.flatten() {
        let Ok(rel) = entry.path().strip_prefix(root) else {
            continue;
        };
        if rel.as_os_str().is_empty() {
            continue;
        }
        if paths.len() == limit {
            paths.clear();
            return Tree {
                root: root.to_string_lossy().into_owned(),
                paths,
                truncated: true,
                folders_only: false,
            };
        }
        let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
        paths.push(tree_path(rel, is_dir));
    }
    Tree {
        root: root.to_string_lossy().into_owned(),
        paths,
        truncated: false,
        folders_only: false,
    }
}

/// Paths directly inside `root` (folders and files at the first level).
fn list_shallow(root: &Path) -> Vec<String> {
    walker(root)
        .max_depth(Some(1))
        .build()
        .flatten()
        .filter_map(|entry| {
            if entry.depth() != 1 {
                return None;
            }
            let Ok(rel) = entry.path().strip_prefix(root) else {
                return None;
            };
            let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
            Some(tree_path(rel, is_dir))
        })
        .collect()
}

/// Whether `root` is the filesystem root (`/` on Unix). Walking it would
/// crawl every mount; the sidebar only ever needs its first level.
pub(super) fn is_filesystem_root(root: &Path) -> bool {
    root.parent().is_none()
}

/// The sidebar's listing of `root`: everything, as `list_tree` lists it, or,
/// past `limit` paths, its folders plus the files at the first level, gathered
/// in the same walk. Past `limit` folders, or once it has looked at
/// `FOLDER_SCAN_FACTOR` times `limit` paths, it still returns that shallow
/// first level, so a huge root (a home folder) answers quickly without leaving
/// the sidebar empty. The filesystem root itself is always shallow: a deep
/// walk there never finishes in time for the page.
pub(super) fn list_tree_or_folders(root: &Path, limit: usize) -> Tree {
    let tree = |paths, truncated, folders_only| Tree {
        root: root.to_string_lossy().into_owned(),
        paths,
        truncated,
        folders_only,
    };
    if is_filesystem_root(root) {
        let shallow = list_shallow(root);
        let any = !shallow.is_empty();
        return tree(shallow, true, any);
    }
    let mut paths = Vec::new();
    let mut folders = Vec::new();
    let mut top_files = Vec::new();
    let mut whole = true;
    for (seen, entry) in walker(root).build().flatten().enumerate() {
        if seen == limit * FOLDER_SCAN_FACTOR {
            let shallow = list_shallow(root);
            let any = !shallow.is_empty();
            return tree(shallow, true, any);
        }
        let Ok(rel) = entry.path().strip_prefix(root) else {
            continue;
        };
        if rel.as_os_str().is_empty() {
            continue;
        }
        let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
        if is_dir {
            if folders.len() == limit {
                let shallow = list_shallow(root);
                let any = !shallow.is_empty();
                return tree(shallow, true, any);
            }
            folders.push(tree_path(rel, true));
        } else if rel.components().count() == 1 {
            top_files.push(tree_path(rel, false));
        }
        if whole && paths.len() == limit {
            whole = false;
            paths = Vec::new();
        }
        if whole {
            paths.push(tree_path(rel, is_dir));
        }
    }
    if whole {
        tree(paths, false, false)
    } else {
        let mut reduced = folders;
        reduced.extend(top_files);
        let any = !reduced.is_empty();
        tree(reduced, true, any)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::scratch;

    fn touch(dir: &Path, rel: &str) {
        let path = dir.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "").unwrap();
    }

    fn sorted(tree: &Tree) -> Vec<&str> {
        let mut paths: Vec<&str> = tree.paths.iter().map(String::as_str).collect();
        paths.sort_unstable();
        paths
    }

    #[test]
    fn root_is_the_nearest_ancestor_with_a_git_entry_else_the_cwd() {
        let dir = scratch();
        std::fs::create_dir_all(dir.join("repo/.git")).unwrap();
        std::fs::create_dir_all(dir.join("repo/src/deep")).unwrap();
        assert_eq!(tree_root(&dir.join("repo/src/deep")), dir.join("repo"));
        assert_eq!(tree_root(&dir.join("repo")), dir.join("repo"));

        // A worktree's `.git` is a file; the nearest one wins over an outer repo.
        std::fs::create_dir_all(dir.join("repo/wt/sub")).unwrap();
        std::fs::write(dir.join("repo/wt/.git"), "gitdir: elsewhere").unwrap();
        assert_eq!(tree_root(&dir.join("repo/wt/sub")), dir.join("repo/wt"));

        std::fs::create_dir_all(dir.join("plain/a")).unwrap();
        assert_eq!(tree_root(&dir.join("plain/a")), dir.join("plain/a"));
    }

    #[test]
    fn lists_relative_paths_with_directories_marked_and_empty_ones_kept() {
        let dir = scratch();
        touch(&dir, "README.md");
        touch(&dir, "src/main.rs");
        touch(&dir, ".env.example");
        std::fs::create_dir(dir.join("docs")).unwrap();
        let tree = list_tree(&dir, TREE_LIMIT_PATHS);
        assert!(!tree.truncated);
        assert_eq!(tree.root, dir.to_string_lossy());
        assert_eq!(
            sorted(&tree),
            [".env.example", "README.md", "docs/", "src/", "src/main.rs"]
        );
    }

    #[test]
    fn respects_gitignore_with_or_without_git_and_never_lists_dot_git() {
        let dir = scratch();
        touch(&dir, ".gitignore");
        std::fs::write(dir.join(".gitignore"), "target/\n*.log\n").unwrap();
        touch(&dir, "target/junk.txt");
        touch(&dir, "run.log");
        touch(&dir, "keep.txt");
        // Not a repo: the ignore file still counts.
        assert_eq!(sorted(&list_tree(&dir, 100)), [".gitignore", "keep.txt"]);

        touch(&dir, ".git/HEAD");
        assert_eq!(sorted(&list_tree(&dir, 100)), [".gitignore", "keep.txt"]);
    }

    #[test]
    fn stops_at_the_cap_and_returns_no_partial_list() {
        let dir = scratch();
        for name in ["a", "b", "c"] {
            touch(&dir, name);
        }
        let at = list_tree(&dir, 3);
        assert!(!at.truncated);
        assert_eq!(at.paths.len(), 3);
        let over = list_tree(&dir, 2);
        assert!(over.truncated);
        assert!(over.paths.is_empty());
    }

    #[test]
    fn the_sidebar_lists_everything_or_past_the_cap_its_folders_and_top_files() {
        let dir = scratch();
        touch(&dir, "src/deep/main.rs");
        touch(&dir, "docs/a.md");
        touch(&dir, "top.txt");
        let whole = list_tree_or_folders(&dir, 10);
        assert!(!whole.truncated && !whole.folders_only);
        assert_eq!(sorted(&whole), sorted(&list_tree(&dir, 10)));
        let reduced = list_tree_or_folders(&dir, 4);
        assert!(reduced.truncated && reduced.folders_only);
        assert_eq!(sorted(&reduced), ["docs/", "src/", "src/deep/", "top.txt"]);
    }

    #[test]
    fn the_sidebar_keeps_the_first_level_past_the_folder_cap_or_scan_budget() {
        let dir = scratch();
        for name in ["a/x", "b/x", "c/x"] {
            touch(&dir, name);
        }
        let over = list_tree_or_folders(&dir, 2);
        assert!(over.truncated && over.folders_only);
        assert_eq!(sorted(&over), ["a/", "b/", "c/"]);
        let dir = scratch();
        for i in 0..20 {
            touch(&dir, &format!("one/{i}"));
        }
        touch(&dir, "README.md");
        let over = list_tree_or_folders(&dir, 5);
        assert!(over.truncated && over.folders_only);
        assert_eq!(sorted(&over), ["README.md", "one/"]);
    }

    #[test]
    fn the_filesystem_root_is_listed_shallow_without_a_deep_walk() {
        assert!(is_filesystem_root(Path::new("/")));
        assert!(!is_filesystem_root(Path::new("/Users")));
        let tree = list_tree_or_folders(Path::new("/"), TREE_LIMIT_PATHS);
        assert!(tree.truncated && tree.folders_only);
        assert_eq!(tree.root, "/");
        assert!(!tree.paths.is_empty());
        assert!(tree.paths.iter().all(|p| !p.trim_end_matches('/').contains('/')));
    }
}
