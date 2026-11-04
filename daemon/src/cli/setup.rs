//! `tabsh setup`: prints the guide a coding agent follows to keep its card on
//! the board current. tabsh never edits an agent's config itself: the agent
//! knows its own hooks better, and keeps knowing them when they change.

const GUIDE: &str = include_str!("setup.md");

/// The guide, with `{tabsh}` replaced by this binary, quoted for a shell,
/// and `{tabsh_js}` and `{url_js}` by it and the daemon's URL as JavaScript
/// strings (for OpenCode's plugin, which runs outside the terminal).
pub(super) fn guide(exe: &str, url: &str) -> String {
    let quoted = format!("'{}'", exe.replace('\'', r"'\''"));
    let js = |s: &str| serde_json::to_string(s).unwrap_or_default();
    GUIDE
        .replace("{tabsh_js}", &js(exe))
        .replace("{url_js}", &js(url))
        .replace("{tabsh}", &quoted)
}

pub(super) fn run() -> i32 {
    // The installed binary's own path, so hooks work even where `tabsh`
    // isn't on the PATH the agent's hooks run with.
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "tabsh".into());
    // Run in a tabsh terminal, this names its daemon.
    let url = std::env::var("TABSH_URL")
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:7681".into());
    print!("{}", guide(&exe, &url));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guide_names_this_binary_and_the_whole_contract() {
        let g = guide("/opt/my tabsh/tabsh", "http://127.0.0.1:7681");
        assert!(!g.contains("{tabsh}"));
        assert!(g.contains("'/opt/my tabsh/tabsh' status in_progress --hook"));
        assert!(g.contains("'/opt/my tabsh/tabsh' status needs_input --hook --if-not completed"));
        assert!(g.contains(
            "status needs_input --hook --if-not completed --note 'Agent finished its turn'"
        ));
        assert!(g.contains("status completed --note '<one line: what you did>'"));
        assert!(
            g.contains("'/opt/my tabsh/tabsh' new --help"),
            "the instructions point the agent at handing work off as cards"
        );

        // Test that paths with single quotes are escaped correctly for shell
        let g_quoted = guide("/opt/it's/tabsh", "http://127.0.0.1:7681");
        assert!(g_quoted.contains("'/opt/it'\\''s/tabsh' status in_progress --hook"));

        // Keywords must be present (case-insensitive except for TABSH_SESSION_ID)
        let g_lower = g.to_lowercase();
        for must_lower in ["back up", "merge", "undo"] {
            assert!(
                g_lower.contains(must_lower),
                "guide must mention {must_lower}"
            );
        }
        // TABSH_SESSION_ID must be exact case
        assert!(
            g.contains("TABSH_SESSION_ID"),
            "guide must mention TABSH_SESSION_ID"
        );
    }

    #[test]
    fn the_opencode_plugin_names_this_binary_and_daemon_as_js_strings() {
        let g = guide("/opt/it's \"x\"/tabsh", "http://127.0.0.1:9000");
        assert!(!g.contains("{tabsh_js}") && !g.contains("{url_js}"));
        assert!(g.contains(r#"const tabsh = "/opt/it's \"x\"/tabsh""#));
        assert!(g.contains(r#"TABSH_URL: "http://127.0.0.1:9000""#));
        assert!(g.contains("id: \"tabsh.board\""));
    }
}
