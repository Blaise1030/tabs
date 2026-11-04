//! Turning a path printed in a terminal into a real file on disk.

use crate::{AppState, sessions};
use std::path::PathBuf;

/// Resolves a path printed in a terminal: `~` is `home`, a relative path is
/// taken from `base`. Symlinks and `..` are resolved. `git diff` prints
/// `a/…` and `b/…` for files that don't have those prefixes, so those are
/// tried without the prefix when the literal path doesn't exist.
pub(super) fn resolve_path(
    base: &std::path::Path,
    home: &std::path::Path,
    input: &str,
) -> Option<PathBuf> {
    let resolve = |s: &str| {
        let path = match s.strip_prefix('~') {
            Some("") => home.to_path_buf(),
            Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
            _ => base.join(s),
        };
        std::fs::canonicalize(path).ok()
    };
    resolve(input).or_else(|| {
        input
            .strip_prefix("a/")
            .or_else(|| input.strip_prefix("b/"))
            .and_then(resolve)
    })
}

/// Where a relative path from this tab is resolved: its shell's live working
/// directory, else the last one saved, else home.
pub(super) fn session_base_dir(st: &AppState, session: &str) -> PathBuf {
    sessions::cwd(st, session)
        .unwrap_or_else(|| std::env::var_os("HOME").map_or_else(|| "/".into(), PathBuf::from))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::scratch;

    #[test]
    fn resolve_path_handles_relative_home_symlinks_and_git_prefixes() {
        let dir = scratch();
        let base = dir.join("proj");
        std::fs::create_dir_all(base.join("src")).unwrap();
        std::fs::write(base.join("src/main.rs"), "fn main() {}").unwrap();
        std::fs::write(base.join("ü notes.md"), "hi").unwrap();
        std::os::unix::fs::symlink(base.join("src/main.rs"), base.join("link.rs")).unwrap();
        let real = std::fs::canonicalize(base.join("src/main.rs")).unwrap();

        assert_eq!(resolve_path(&base, &dir, "src/main.rs"), Some(real.clone()));
        assert_eq!(
            resolve_path(&base, &dir, "./src/../src/main.rs"),
            Some(real.clone())
        );
        assert_eq!(
            resolve_path(&base, &dir, "~/proj/src/main.rs"),
            Some(real.clone())
        );
        assert_eq!(resolve_path(&base, &dir, "link.rs"), Some(real.clone()));
        assert_eq!(
            resolve_path(&base, &dir, "a/src/main.rs"),
            Some(real.clone())
        );
        assert_eq!(resolve_path(&base, &dir, "b/src/main.rs"), Some(real));
        assert!(resolve_path(&base, &dir, "ü notes.md").is_some());
        assert_eq!(
            resolve_path(&base, &dir, "~"),
            Some(std::fs::canonicalize(&dir).unwrap())
        );
        assert_eq!(resolve_path(&base, &dir, "missing.rs"), None);
        assert_eq!(resolve_path(&base, &dir, "a/missing.rs"), None);
    }
}
