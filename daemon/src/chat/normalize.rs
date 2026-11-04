//! ACP events → the `UiChunk`s the browser renders (Task 3, locked shape).

// Consumers (manager/routes) land in Tasks 4/6; tests exercise this now.
#![allow(dead_code)]
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::acp::AcpEvent;

/// One line of the chat transcript / one SSE `data:` payload.
///
/// Locked shape for Tasks 4/6: a flat object discriminated by `type`
/// (snake_case). Variants are only added, never renamed or removed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum UiChunk {
    /// Streaming agent text (`agent_message_chunk`).
    TextDelta { session_id: String, text: String },
    /// Streaming agent reasoning text (`agent_thought_chunk`).
    ThoughtDelta { session_id: String, text: String },
    /// Echo of a user message chunk.
    UserText { session_id: String, text: String },
    /// A tool call (or its update); `tool_call` is the raw ACP update minus
    /// its `sessionUpdate` discriminator.
    ToolCall {
        session_id: String,
        tool_call: Value,
    },
    ToolCallUpdate {
        session_id: String,
        tool_call: Value,
    },
    /// The agent's plan; `entries` is the raw ACP plan entries array.
    Plan { session_id: String, entries: Value },
    /// A permission request. `request_id` is the JSON-RPC id (stringified).
    /// The UI answers it with `POST …/chat/approve`.
    Permission {
        session_id: String,
        request_id: String,
        tool_call: Value,
        options: Value,
    },
    /// The user answered a permission request. Kept in the transcript so
    /// the UI can hide that request across reloads.
    PermissionAnswered {
        session_id: String,
        request_id: String,
        allow: bool,
    },
    /// A prompt turn finished; `stop_reason` is the ACP `stopReason`
    /// (e.g. `end_turn`, `cancelled`).
    TurnEnd {
        session_id: String,
        stop_reason: String,
    },
    /// Anything else, kept raw so no agent output is silently dropped.
    Unknown { session_id: String, update: Value },
    /// A spawn, auth, or protocol failure. `message` is the daemon's
    /// string; the panel runs it through its hint for install or login.
    Error { message: String },
}

fn without_discriminator(update: &Value) -> Value {
    let mut update = update.clone();
    if let Some(obj) = update.as_object_mut() {
        obj.remove("sessionUpdate");
    }
    update
}

pub(crate) fn to_chunks(ev: &AcpEvent) -> Vec<UiChunk> {
    let chunk = match ev {
        AcpEvent::AgentMessageChunk { session_id, text } => UiChunk::TextDelta {
            session_id: session_id.clone(),
            text: text.clone(),
        },
        AcpEvent::AgentThoughtChunk { session_id, text } => UiChunk::ThoughtDelta {
            session_id: session_id.clone(),
            text: text.clone(),
        },
        AcpEvent::UserMessageChunk { session_id, text } => UiChunk::UserText {
            session_id: session_id.clone(),
            text: text.clone(),
        },
        AcpEvent::ToolCall { session_id, update } => UiChunk::ToolCall {
            session_id: session_id.clone(),
            tool_call: without_discriminator(update),
        },
        AcpEvent::ToolCallUpdate { session_id, update } => UiChunk::ToolCallUpdate {
            session_id: session_id.clone(),
            tool_call: without_discriminator(update),
        },
        AcpEvent::Plan { session_id, update } => UiChunk::Plan {
            session_id: session_id.clone(),
            entries: update.get("entries").cloned().unwrap_or(Value::Null),
        },
        AcpEvent::PermissionRequest {
            session_id,
            request_id,
            tool_call,
            options,
        } => UiChunk::Permission {
            session_id: session_id.clone(),
            request_id: request_id.clone(),
            tool_call: tool_call.clone(),
            options: options.clone(),
        },
        AcpEvent::PromptEnded {
            session_id,
            stop_reason,
        } => UiChunk::TurnEnd {
            session_id: session_id.clone(),
            stop_reason: stop_reason.clone(),
        },
        // Status mapping consumes this; the transcript has no chunk for it.
        AcpEvent::SessionEnded { .. } | AcpEvent::AgentExited => return Vec::new(),
        AcpEvent::Unknown { session_id, update } => UiChunk::Unknown {
            session_id: session_id.clone(),
            update: update.clone(),
        },
    };
    vec![chunk]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_message_chunk_serializes_with_type_tag() {
        let chunks = to_chunks(&AcpEvent::AgentMessageChunk {
            session_id: "s1".into(),
            text: "hi".into(),
        });
        assert_eq!(
            serde_json::to_value(&chunks[0]).unwrap(),
            serde_json::json!({"type": "text_delta", "session_id": "s1", "text": "hi"})
        );
    }

    #[test]
    fn prompt_ended_becomes_turn_end() {
        let chunks = to_chunks(&AcpEvent::PromptEnded {
            session_id: "s1".into(),
            stop_reason: "cancelled".into(),
        });
        assert_eq!(
            serde_json::to_value(&chunks[0]).unwrap(),
            serde_json::json!({"type": "turn_end", "session_id": "s1", "stop_reason": "cancelled"})
        );
    }
}
