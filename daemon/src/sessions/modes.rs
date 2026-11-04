//! Which terminal modes (alternate screen, mouse reporting, cursor visibility…)
//! are in effect, so replayed scrollback can put a fresh terminal back into them.

/// Shown between saved output and the fresh shell after a daemon restart. It
/// first undoes modes a dead program may have left on (alt screen, mouse
/// reporting, bracketed paste, hidden cursor, colors).
pub(super) const RESTORE_MARKER: &[u8] =
    b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?25h\x1b[0m\
\r\n\x1b[2m--- restored: tabsh restarted ---\x1b[0m\r\n";

/// DEC private modes worth restoring on replay: cursor keys, autowrap,
/// cursor visibility, alt screen, mouse reporting, focus events, bracketed
/// paste. A full-screen program usually turns these on once at startup, so
/// after enough redraws the bytes that did it fall out of the scrollback.
const TRACKED_MODES: &[u16] = &[
    1, 7, 25, 47, 1047, 1049, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 2004,
];

/// Follows `ESC [ ? Pm h` / `ESC [ ? Pm l` through a byte stream, which may
/// split sequences anywhere, and remembers the last setting of each mode.
#[derive(Default)]
pub(super) struct ModeTracker {
    modes: std::collections::BTreeMap<u16, bool>,
    state: ScanState,
    params: Vec<u8>,
}

#[derive(Default, PartialEq)]
enum ScanState {
    #[default]
    Ground,
    Esc,
    Csi,
    Private,
}

impl ModeTracker {
    pub(super) fn feed(&mut self, bytes: impl IntoIterator<Item = u8>) {
        for b in bytes {
            self.state = match (&self.state, b) {
                (_, 0x1b) => ScanState::Esc,
                (ScanState::Esc, b'[') => ScanState::Csi,
                (ScanState::Csi, b'?') => {
                    self.params.clear();
                    ScanState::Private
                }
                (ScanState::Private, b'0'..=b'9' | b';') if self.params.len() < 64 => {
                    self.params.push(b);
                    ScanState::Private
                }
                (ScanState::Private, b'h' | b'l') => {
                    for p in self.params.split(|&c| c == b';') {
                        let mode = std::str::from_utf8(p).ok().and_then(|p| p.parse().ok());
                        if let Some(mode) = mode.filter(|m| TRACKED_MODES.contains(m)) {
                            self.modes.insert(mode, b == b'h');
                        }
                    }
                    ScanState::Ground
                }
                _ => ScanState::Ground,
            };
        }
    }

    /// Escape sequences that put a fresh terminal into the tracked state.
    pub(super) fn replay_prefix(&self) -> Vec<u8> {
        self.modes
            .iter()
            .flat_map(|(mode, on)| {
                format!("\x1b[?{mode}{}", if *on { 'h' } else { 'l' }).into_bytes()
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_tracker_follows_split_sequences() {
        let mut t = ModeTracker::default();
        t.feed(*b"\x1b[?1049h\x1b[?1000;10");
        t.feed(*b"06h hello \x1b[?25l\x1b[?1000l\x1b[?9h");
        assert_eq!(
            t.replay_prefix(),
            b"\x1b[?25l\x1b[?1000l\x1b[?1006h\x1b[?1049h"
        );
    }
}
