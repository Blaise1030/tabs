//! Append-only chat transcripts: one JSONL file per card at
//! `{data_dir}/chats/{session_id}.jsonl`, one `UiChunk` per line — the
//! same JSON the SSE stream sends, so history survives daemon restarts.

use std::{
    io::Write,
    path::{Path, PathBuf},
};

use super::normalize::UiChunk;

/// Whether `id` is safe as a transcript file name (tabsh session ids are
/// hex-and-dash tokens; anything else never names a file).
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub(crate) fn path(data_dir: &Path, session_id: &str) -> PathBuf {
    data_dir.join("chats").join(format!("{session_id}.jsonl"))
}

/// Appends one chunk as a JSON line, creating the chats dir on first use.
pub(crate) fn append(data_dir: &Path, session_id: &str, chunk: &UiChunk) -> std::io::Result<()> {
    if !valid_id(session_id) {
        return Ok(());
    }
    let path = path(data_dir, session_id);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut line = serde_json::to_string(chunk).unwrap_or_default();
    line.push('\n');
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    file.write_all(line.as_bytes())
}

/// Every chunk recorded for a card, oldest first. A missing file is an
/// empty history; unreadable lines are skipped, never fatal.
///
/// A turn left open (daemon kill mid-prompt, agent hang without
/// `PromptEnded`) is sealed with `turn_end`/`cancelled` so the panel does
/// not stay `busy` forever and queue every send without POSTing.
pub(crate) fn load(data_dir: &Path, session_id: &str) -> Vec<UiChunk> {
    if !valid_id(session_id) {
        return Vec::new();
    }
    let Ok(text) = std::fs::read_to_string(path(data_dir, session_id)) else {
        return Vec::new();
    };
    let mut chunks: Vec<UiChunk> = text
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    seal_open_turn(data_dir, session_id, &mut chunks);
    chunks
}

fn turn_open(chunks: &[UiChunk]) -> bool {
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

fn last_session_id(chunks: &[UiChunk]) -> String {
    for chunk in chunks.iter().rev() {
        let id = match chunk {
            UiChunk::TextDelta { session_id, .. }
            | UiChunk::ThoughtDelta { session_id, .. }
            | UiChunk::UserText { session_id, .. }
            | UiChunk::ToolCall { session_id, .. }
            | UiChunk::ToolCallUpdate { session_id, .. }
            | UiChunk::Plan { session_id, .. }
            | UiChunk::Permission { session_id, .. }
            | UiChunk::PermissionAnswered { session_id, .. }
            | UiChunk::TurnEnd { session_id, .. }
            | UiChunk::Unknown { session_id, .. } => session_id.as_str(),
            UiChunk::Error { .. } => continue,
        };
        if !id.is_empty() {
            return id.to_string();
        }
    }
    String::new()
}

fn seal_open_turn(data_dir: &Path, session_id: &str, chunks: &mut Vec<UiChunk>) {
    if !turn_open(chunks) {
        return;
    }
    let end = UiChunk::TurnEnd {
        session_id: last_session_id(chunks),
        stop_reason: "cancelled".into(),
    };
    let _ = append(data_dir, session_id, &end);
    chunks.push(end);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_then_load_round_trips() {
        let dir = crate::test_support::scratch();
        let chunk = UiChunk::TextDelta {
            session_id: "s1".into(),
            text: "hi".into(),
        };
        append(&dir, "card-1", &chunk).unwrap();
        append(&dir, "card-1", &chunk).unwrap();
        assert_eq!(load(&dir, "card-1"), vec![chunk.clone(), chunk]);
        assert!(path(&dir, "card-1").ends_with("chats/card-1.jsonl"));
        assert!(load(&dir, "missing").is_empty());
        assert!(load(&dir, "../evil").is_empty());
    }

    #[test]
    fn load_seals_a_turn_left_open_without_turn_end() {
        let dir = crate::test_support::scratch();
        append(
            &dir,
            "card-2",
            &UiChunk::UserText {
                session_id: "acp-1".into(),
                text: "hi".into(),
            },
        )
        .unwrap();
        append(
            &dir,
            "card-2",
            &UiChunk::TextDelta {
                session_id: "acp-1".into(),
                text: "partial".into(),
            },
        )
        .unwrap();
        let chunks = load(&dir, "card-2");
        assert!(matches!(
            chunks.last(),
            Some(UiChunk::TurnEnd {
                stop_reason,
                session_id
            }) if stop_reason == "cancelled" && session_id == "acp-1"
        ));
        // A second load must not append another seal.
        assert_eq!(load(&dir, "card-2").len(), chunks.len());
    }
}
