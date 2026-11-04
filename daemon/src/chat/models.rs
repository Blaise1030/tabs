//! Select options from ACP `configOptions` (`session/new` /
//! `set_config_option`): the model and the session mode (how the agent
//! asks permission).

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ModelChoice {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SelectConfig {
    /// ACP `configOptions` id (usually `"model"` or `"mode"`).
    pub config_id: String,
    pub current: String,
    pub options: Vec<ModelChoice>,
}

pub(crate) type ModelConfig = SelectConfig;
pub(crate) type ModeConfig = SelectConfig;

/// The select options an agent advertised at `session/new` or in a
/// `session/set_config_option` reply. Both are refreshed together, since
/// the reply always carries the complete configuration state.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ConfigOptions {
    pub model: Option<ModelConfig>,
    pub mode: Option<ModeConfig>,
}

pub(crate) fn parse_config_options(config_options: &Value) -> ConfigOptions {
    ConfigOptions {
        model: parse_model_config(config_options),
        mode: parse_mode_config(config_options),
    }
}

/// Finds the model select option in an ACP `configOptions` array.
pub(crate) fn parse_model_config(config_options: &Value) -> Option<ModelConfig> {
    select_config(config_options, is_model_option)
}

/// Finds the session-mode select option (how the agent asks permission).
pub(crate) fn parse_mode_config(config_options: &Value) -> Option<ModeConfig> {
    select_config(config_options, is_mode_option)
}

fn select_config(config_options: &Value, wanted: fn(&Value) -> bool) -> Option<SelectConfig> {
    let list = config_options.as_array()?;
    let opt = list.iter().find(|o| wanted(o))?;
    let config_id = opt.get("id").and_then(Value::as_str)?.to_string();
    let current = opt
        .get("currentValue")
        .or_else(|| opt.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let mut options = Vec::new();
    flatten_choices(opt.get("options"), &mut options);
    if options.is_empty() {
        return None;
    }
    Some(SelectConfig {
        config_id,
        current,
        options,
    })
}

fn flatten_choices(node: Option<&Value>, out: &mut Vec<ModelChoice>) {
    let Some(node) = node else { return };
    let Some(arr) = node.as_array() else { return };
    for entry in arr {
        if let Some(s) = entry.as_str() {
            out.push(ModelChoice {
                id: s.to_string(),
                name: s.to_string(),
                description: None,
            });
            continue;
        }
        // Nested groups (provider → models): recurse into `options`.
        if entry.get("options").and_then(Value::as_array).is_some()
            && entry.get("value").is_none()
            && entry.get("id").is_none()
        {
            flatten_choices(entry.get("options"), out);
            continue;
        }
        let Some(id) = entry
            .get("value")
            .or_else(|| entry.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            // Group with only a name + nested options.
            flatten_choices(entry.get("options"), out);
            continue;
        };
        let name = entry
            .get("name")
            .or_else(|| entry.get("title"))
            .and_then(Value::as_str)
            .unwrap_or(&id)
            .to_string();
        let description = entry
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string);
        out.push(ModelChoice {
            id,
            name,
            description,
        });
    }
}

fn is_model_option(opt: &Value) -> bool {
    is_option(opt, "model")
}

fn is_mode_option(opt: &Value) -> bool {
    is_option(opt, "mode")
}

fn is_option(opt: &Value, wanted: &str) -> bool {
    let id = opt.get("id").and_then(Value::as_str).unwrap_or("");
    let category = opt.get("category").and_then(Value::as_str).unwrap_or("");
    let name = opt.get("name").and_then(Value::as_str).unwrap_or("");
    id.eq_ignore_ascii_case(wanted)
        || category.eq_ignore_ascii_case(wanted)
        || name.eq_ignore_ascii_case(wanted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_model_config_reads_id_model_options() {
        let cfg = parse_model_config(&json!([
            {
                "id": "mode",
                "category": "mode",
                "currentValue": "default",
                "options": [{"value": "default", "name": "Default"}]
            },
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "currentValue": "fast",
                "options": [
                    {"value": "fast", "name": "Fast"},
                    {"value": "smart", "name": "Smart"}
                ]
            }
        ]))
        .expect("model option");
        assert_eq!(cfg.config_id, "model");
        assert_eq!(cfg.current, "fast");
        assert_eq!(cfg.options.len(), 2);
        assert_eq!(cfg.options[1].name, "Smart");
    }

    #[test]
    fn parse_model_config_matches_category_when_id_differs() {
        let cfg = parse_model_config(&json!([{
            "id": "llm",
            "category": "model",
            "currentValue": "a",
            "options": [{"id": "a", "title": "Alpha"}, {"id": "b", "title": "Beta"}]
        }]))
        .expect("category model");
        assert_eq!(cfg.config_id, "llm");
        assert_eq!(cfg.options[0].id, "a");
        assert_eq!(cfg.options[0].name, "Alpha");
    }

    #[test]
    fn parse_model_config_returns_none_without_choices() {
        assert!(parse_model_config(&json!([])).is_none());
        assert!(
            parse_model_config(&json!([{
                "id": "model",
                "currentValue": "x",
                "options": []
            }]))
            .is_none()
        );
        assert!(parse_model_config(&json!({"not": "array"})).is_none());
    }

    #[test]
    fn parse_mode_config_reads_the_mode_category() {
        let cfg = parse_mode_config(&json!([
            {
                "id": "model",
                "category": "model",
                "currentValue": "fast",
                "options": [{"value": "fast", "name": "Fast"}]
            },
            {
                "id": "mode",
                "name": "Session Mode",
                "category": "mode",
                "currentValue": "ask",
                "options": [
                    {"value": "ask", "name": "Ask"},
                    {"value": "code", "name": "Code"}
                ]
            }
        ]))
        .expect("mode option");
        assert_eq!(cfg.config_id, "mode");
        assert_eq!(cfg.current, "ask");
        assert_eq!(
            cfg.options
                .iter()
                .map(|o| o.name.as_str())
                .collect::<Vec<_>>(),
            ["Ask", "Code"]
        );
    }

    #[test]
    fn parse_mode_config_needs_selectable_values() {
        // A boolean-style option is not a select the picker can render.
        assert!(
            parse_mode_config(&json!([{
                "id": "mode",
                "category": "mode",
                "type": "boolean",
                "currentValue": true
            }]))
            .is_none()
        );
        assert!(parse_mode_config(&json!([{"id": "model"}])).is_none());
    }

    #[test]
    fn parse_config_options_keeps_model_and_mode_apart() {
        let cfg = parse_config_options(&json!([
            {
                "id": "mode",
                "category": "mode",
                "currentValue": "ask",
                "options": [{"value": "ask", "name": "Ask"}]
            },
            {
                "id": "model",
                "category": "model",
                "currentValue": "fast",
                "options": [{"value": "fast", "name": "Fast"}]
            }
        ]));
        assert_eq!(cfg.model.expect("model").current, "fast");
        assert_eq!(cfg.mode.expect("mode").current, "ask");
    }

    #[test]
    fn parse_model_config_flattens_groups_and_string_entries() {
        let cfg = parse_model_config(&json!([{
            "id": "model",
            "name": "Model",
            "currentValue": "auto",
            "options": [
                "auto",
                {
                    "name": "Claude",
                    "options": [
                        {"value": "opus", "name": "Opus"},
                        {"value": "sonnet", "name": "Sonnet"}
                    ]
                }
            ]
        }]))
        .expect("model");
        assert_eq!(cfg.current, "auto");
        assert_eq!(
            cfg.options
                .iter()
                .map(|o| o.id.as_str())
                .collect::<Vec<_>>(),
            ["auto", "opus", "sonnet"]
        );
    }
}
