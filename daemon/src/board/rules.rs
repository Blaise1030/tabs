//! Whether a status update applies to a card.

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Source {
    /// The agent's hooks and instructions, through `tabsh status`.
    Hook,
    /// The board: a drag always wins.
    User,
}

/// Hooks never touch an archived card, and skip the update when the card is
/// in the `unless` status (the Stop hook passes `completed`).
pub(crate) fn applies(current: &str, source: Source, unless: Option<&str>) -> bool {
    match source {
        Source::User => true,
        Source::Hook => current != "archived" && unless != Some(current),
    }
}

/// A card dragged to In progress starts its agent (when it has one waiting);
/// hooks only report on an agent that's already running.
pub(crate) fn launches(status: &str, source: Source) -> bool {
    source == Source::User && status == "in_progress"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_board_always_wins() {
        assert!(applies("archived", Source::User, None));
        assert!(applies("completed", Source::User, Some("completed")));
    }

    #[test]
    fn hooks_leave_archived_cards_alone() {
        assert!(!applies("archived", Source::Hook, None));
    }

    #[test]
    fn unless_skips_only_that_status() {
        assert!(!applies("completed", Source::Hook, Some("completed")));
        assert!(applies("in_progress", Source::Hook, Some("completed")));
        assert!(applies("completed", Source::Hook, None));
    }

    #[test]
    fn only_a_drag_to_in_progress_launches() {
        assert!(launches("in_progress", Source::User));
        assert!(!launches("in_progress", Source::Hook));
        assert!(!launches("needs_input", Source::User));
    }
}
