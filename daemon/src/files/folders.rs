//! The New card dialog's folder search: the subfolders that complete a typed path.

use std::path::{Path, PathBuf};

/// How many folders one search returns.
pub(super) const FOLDER_LIMIT: usize = 50;

/// The folders that complete `input`, the way a shell completes a path: the
/// subfolders of its parent whose names start with its last part, ignoring
/// case, sorted. `~` is `home`. Hidden folders only match a part that starts
/// with `.`. A relative path, or a parent that isn't there, matches nothing.
pub(super) fn matching_folders(home: &Path, input: &str, limit: usize) -> Vec<String> {
    let expanded = match input.strip_prefix('~') {
        Some("") => home.join(""),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => PathBuf::from(input),
    };
    if !expanded.is_absolute() {
        return Vec::new();
    }
    // `a/b` completes `b` in `a`; `a/b/` lists all of `b`.
    let text = expanded.to_string_lossy();
    let (parent, part) = text.rsplit_once('/').unwrap_or(("", &text));
    let parent = if parent.is_empty() { "/" } else { parent };
    let part = part.to_lowercase();
    let Ok(entries) = std::fs::read_dir(parent) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|name| {
            (part.starts_with('.') || !name.starts_with('.'))
                && name.to_lowercase().starts_with(&part)
        })
        .filter(|name| Path::new(parent).join(name).is_dir())
        .collect();
    names.sort_by_key(|name| name.to_lowercase());
    names
        .into_iter()
        .take(limit)
        .map(|name| Path::new(parent).join(name).to_string_lossy().into_owned())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::scratch;

    fn tree() -> PathBuf {
        let dir = scratch();
        for d in [
            "code/tabsh",
            "code/Talks",
            "code/zed",
            "code/.tabby",
            "notes",
        ] {
            std::fs::create_dir_all(dir.join(d)).unwrap();
        }
        std::fs::write(dir.join("code/tab.txt"), "").unwrap();
        dir
    }

    fn s(p: PathBuf) -> String {
        p.to_string_lossy().into_owned()
    }

    #[test]
    fn completes_the_last_part_ignoring_case_and_files() {
        let dir = tree();
        let input = format!("{}/code/ta", dir.display());
        assert_eq!(
            matching_folders(&dir, &input, FOLDER_LIMIT),
            [s(dir.join("code/tabsh")), s(dir.join("code/Talks"))]
        );
    }

    #[test]
    fn a_trailing_slash_lists_every_visible_subfolder() {
        let dir = tree();
        let input = format!("{}/code/", dir.display());
        assert_eq!(
            matching_folders(&dir, &input, FOLDER_LIMIT),
            [
                s(dir.join("code/tabsh")),
                s(dir.join("code/Talks")),
                s(dir.join("code/zed"))
            ]
        );
    }

    #[test]
    fn hidden_folders_match_a_dot() {
        let dir = tree();
        let input = format!("{}/code/.t", dir.display());
        assert_eq!(
            matching_folders(&dir, &input, FOLDER_LIMIT),
            [s(dir.join("code/.tabby"))]
        );
    }

    #[test]
    fn tilde_is_home() {
        let dir = tree();
        assert_eq!(
            matching_folders(&dir, "~/no", FOLDER_LIMIT),
            [s(dir.join("notes"))]
        );
        assert_eq!(
            matching_folders(&dir, "~", FOLDER_LIMIT),
            [s(dir.join("code")), s(dir.join("notes"))]
        );
    }

    #[test]
    fn symlinked_folders_count() {
        let dir = tree();
        std::os::unix::fs::symlink(dir.join("notes"), dir.join("code/tabs-link")).unwrap();
        let input = format!("{}/code/tabs", dir.display());
        assert_eq!(
            matching_folders(&dir, &input, FOLDER_LIMIT),
            [s(dir.join("code/tabs-link")), s(dir.join("code/tabsh"))]
        );
    }

    #[test]
    fn relative_or_missing_paths_match_nothing() {
        let dir = tree();
        assert!(matching_folders(&dir, "", FOLDER_LIMIT).is_empty());
        assert!(matching_folders(&dir, "code/ta", FOLDER_LIMIT).is_empty());
        let missing = format!("{}/nope/ta", dir.display());
        assert!(matching_folders(&dir, &missing, FOLDER_LIMIT).is_empty());
    }

    #[test]
    fn stops_at_the_limit() {
        let dir = tree();
        let input = format!("{}/code/", dir.display());
        assert_eq!(
            matching_folders(&dir, &input, 2),
            [s(dir.join("code/tabsh")), s(dir.join("code/Talks"))]
        );
    }
}
