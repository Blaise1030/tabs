//! `tabsh status`: sets the card of the terminal it runs in. Hooks call it
//! with `--hook`, which must never disturb the agent: silent, always exit 0.

use super::daemon::{Env, request};
use crate::board::STATUSES;
use std::io::Read;

#[derive(Debug)]
pub(super) struct Parsed {
    pub(super) status: String,
    pub(super) note: Option<String>,
    pub(super) unless: Option<String>,
    pub(super) hook: bool,
    /// Under `--hook`, one trailing argument some agents pass their event
    /// JSON in (instead of stdin).
    pub(super) payload: Option<String>,
}

pub(super) fn parse(args: &[String]) -> Result<Parsed, String> {
    let mut it = args.iter();
    let (mut status, mut note, mut unless, mut hook) = (None, None, None, false);
    let mut extra: Vec<&String> = Vec::new();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--hook" => hook = true,
            "--note" => note = Some(it.next().ok_or("--note needs a value")?.clone()),
            "--if-not" => unless = Some(it.next().ok_or("--if-not needs a status")?.clone()),
            s if !s.starts_with("--") && status.is_none() => status = Some(s.to_owned()),
            _ if status.is_some() && extra.is_empty() => extra.push(a),
            other => return Err(format!("unexpected argument '{other}'")),
        }
    }
    // `a` above also takes flags like `--bogus` after the status; only hook mode
    // may carry one extra argument, and it can't look like a flag.
    if let Some(a) = extra.first()
        && (!hook || a.starts_with("--"))
    {
        return Err(format!("unexpected argument '{a}'"));
    }
    let payload = extra.first().map(|a| (*a).clone());
    let status =
        status.ok_or("which status? backlog, in_progress, needs_input, completed or archived")?;
    for s in [Some(&status), unless.as_ref()].into_iter().flatten() {
        if !STATUSES.contains(&s.as_str()) {
            return Err(format!(
                "unknown status '{s}' (use {})",
                STATUSES.join(", ")
            ));
        }
    }
    Ok(Parsed {
        status,
        note,
        unless,
        hook,
        payload,
    })
}

/// What tabsh uses from the hook event an agent writes on stdin (or passes
/// as the trailing argument).
#[derive(Default, Debug, PartialEq)]
pub(super) struct HookEvent {
    /// Claude Code's and Gemini CLI's Notification payloads have one; other
    /// events don't.
    pub(super) message: Option<String>,
    /// The agent's conversation, which a restart resumes.
    pub(super) session: Option<String>,
    /// The agent stopped only to wait for its subagents, which wake it again
    /// (Claude Code's Stop payload lists them in `background_tasks`). Shells
    /// and monitors don't count: a dev server may never end.
    pub(super) waiting: bool,
}

pub(super) fn read_event(stdin: &mut dyn Read) -> HookEvent {
    let mut buf = Vec::new();
    if stdin.take(64 * 1024).read_to_end(&mut buf).is_err() {
        return HookEvent::default();
    }
    event_of(&buf)
}

fn event_of(json: impl AsRef<[u8]>) -> HookEvent {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(json.as_ref()) else {
        return HookEvent::default();
    };
    let text = |k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let agent = |t: &serde_json::Value| {
        matches!(
            t.get("type").and_then(|x| x.as_str()),
            Some("subagent" | "workflow")
        )
    };
    HookEvent {
        message: text("message"),
        session: text("session_id"),
        waiting: v
            .get("background_tasks")
            .and_then(|x| x.as_array())
            .is_some_and(|tasks| tasks.iter().any(agent)),
    }
}

pub(super) fn run(args: &[String], env: &Env, stdin: &mut dyn Read) -> i32 {
    let hook = args.iter().any(|a| a == "--hook");
    match set(args, env, stdin) {
        Ok(()) => 0,
        Err(_) if hook => 0,
        Err(e) => {
            eprintln!("tabsh status: {e}");
            1
        }
    }
}

fn set(args: &[String], env: &Env, stdin: &mut dyn Read) -> Result<(), String> {
    let p = parse(args)?;
    let event = match (p.hook, p.payload.as_deref()) {
        (false, _) => HookEvent::default(),
        (true, Some(json)) => event_of(json),
        (true, None) => read_event(stdin),
    };
    // Its turn ended, but not its work: the card stays as it is.
    if event.waiting {
        return Ok(());
    }
    let plain = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    // Inside a tabsh terminal, its card; else (a hook running in an agent's
    // server, like OpenCode's plugins) the card whose agent has the
    // conversation the hook names.
    let path = match (env.session.as_deref(), event.session.as_deref()) {
        (Some(id), _) if id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') => {
            format!("/api/sessions/{id}/status")
        }
        (Some(id), _) => return Err(format!("odd TABSH_SESSION_ID '{id}'")),
        (None, Some(s)) if p.hook && plain(s) => format!("/api/board/agents/{s}/status"),
        (None, _) => return Err("not inside a tabsh terminal (TABSH_SESSION_ID is not set)".into()),
    };
    let note = p.note.or(event.message);
    let (agent, agent_session) = (env.agent, event.session);
    let body = serde_json::json!({
        "status": p.status,
        "note": note,
        "source": "hook",
        "unless": p.unless,
        "agent": agent,
        "agent_session": agent_session,
    })
    .to_string();
    match request(env, "PATCH", &path, Some(&body))?.code {
        200 => Ok(()),
        404 => Err("this terminal's card no longer exists".into()),
        code => Err(format!("the daemon answered {code}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{sessions::store::insert_session, state::router, test_support::test_state};

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }
    fn env(session: Option<&str>, url: &str) -> Env {
        Env {
            session: session.map(String::from),
            url: url.into(),
            token: Some("t0k3n".into()),
            agent: None,
            conversation: None,
        }
    }

    #[test]
    fn hook_mode_never_fails() {
        let e = env(None, "http://127.0.0.1:9");
        assert_eq!(run(&args("in_progress --hook"), &e, &mut &b""[..]), 0);
        let e = env(Some("x"), "http://127.0.0.1:9"); // nothing listens on port 9
        assert_eq!(run(&args("in_progress --hook"), &e, &mut &b""[..]), 0);
        assert_eq!(run(&args("bogus --hook"), &e, &mut &b""[..]), 0);
    }

    #[test]
    fn by_hand_errors_exit_1() {
        assert_eq!(
            run(
                &args("completed"),
                &env(None, "http://127.0.0.1:9"),
                &mut &b""[..]
            ),
            1
        );
        assert_eq!(
            run(
                &args("completed"),
                &env(Some("x"), "http://127.0.0.1:9"),
                &mut &b""[..]
            ),
            1
        );
        assert_eq!(
            run(
                &args("doing"),
                &env(Some("x"), "http://127.0.0.1:9"),
                &mut &b""[..]
            ),
            1
        );
        assert_eq!(
            run(
                &args(""),
                &env(Some("x"), "http://127.0.0.1:9"),
                &mut &b""[..]
            ),
            1
        );
    }

    #[test]
    fn parses_flags() {
        let p = parse(&args("needs_input --hook --if-not completed --note hi")).unwrap();
        assert_eq!(
            (
                p.status.as_str(),
                p.hook,
                p.unless.as_deref(),
                p.note.as_deref()
            ),
            ("needs_input", true, Some("completed"), Some("hi"))
        );
        let p = parse(&[
            "completed".into(),
            "--note".into(),
            "Added tests, all green".into(),
        ])
        .unwrap();
        assert_eq!(p.note.as_deref(), Some("Added tests, all green"));
        assert!(parse(&args("completed --note")).is_err());
    }

    #[test]
    fn a_hook_note_comes_from_the_notification_message() {
        let stdin = br#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#;
        assert_eq!(
            read_event(&mut &stdin[..]).message.as_deref(),
            Some("Claude needs your permission to use Bash")
        );
        assert_eq!(read_event(&mut &br#"{"prompt":"hi"}"#[..]).message, None);
        assert_eq!(read_event(&mut &b"not json"[..]), HookEvent::default());
    }

    #[test]
    fn a_hook_event_names_its_conversation() {
        let stdin =
            br#"{"hook_event_name":"UserPromptSubmit","session_id":"3f1c-9a","prompt":"hi"}"#;
        assert_eq!(
            read_event(&mut &stdin[..]),
            HookEvent {
                message: None,
                session: Some("3f1c-9a".into()),
                waiting: false,
            }
        );
    }

    #[test]
    fn a_stop_with_agents_in_flight_is_waiting() {
        let stop = |tasks: &str| {
            event_of(format!(
                r#"{{"hook_event_name":"Stop","background_tasks":{tasks}}}"#
            ))
            .waiting
        };
        assert!(stop(
            r#"[{"id":"a1","type":"subagent","status":"running"}]"#
        ));
        assert!(stop(
            r#"[{"id":"w1","type":"workflow","status":"pending"}]"#
        ));
        assert!(!stop("[]"));
        assert!(
            !stop(r#"[{"id":"b1","type":"shell","status":"running"}]"#),
            "a dev server may never end, and never wakes the agent"
        );
        assert!(!event_of(r#"{"hook_event_name":"Stop"}"#).waiting);
    }

    #[test]
    fn hook_mode_takes_one_trailing_payload_argument() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let p = parse(&a(&["completed", "--hook", r#"{"message":"hi"}"#])).unwrap();
        assert_eq!(p.payload.as_deref(), Some(r#"{"message":"hi"}"#));
        assert!(p.hook);
        assert!(parse(&a(&["completed", "--hook", "x", "y"])).is_err());
        assert!(parse(&a(&["completed", "--hook", "--bogus"])).is_err());
        assert!(
            parse(&a(&["completed", r#"{"message":"hi"}"#])).is_err(),
            "without --hook an extra positional stays an error"
        );
        assert_eq!(
            event_of(r#"{"message":"hi"}"#).message.as_deref(),
            Some("hi")
        );
        assert_eq!(event_of("nope").message, None);
        assert_eq!(event_of(r#"{"message":3}"#).message, None);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn it_moves_a_real_card() {
        let st = test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = router(st.clone());
        tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
        });
        let (u, i) = (url.clone(), id.clone());
        let code = tokio::task::spawn_blocking(move || {
            run(
                &args("completed --note done"),
                &env(Some(&i), &u),
                &mut &b""[..],
            )
        })
        .await
        .unwrap();
        assert_eq!(code, 0);
        let status: String = st
            .db
            .lock()
            .unwrap()
            .query_row("SELECT status FROM sessions WHERE id = ?1", [&id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(status, "completed");
        let code = tokio::task::spawn_blocking(move || {
            run(&args("completed"), &env(Some("gone"), &url), &mut &b""[..])
        })
        .await
        .unwrap();
        assert_eq!(code, 1, "unknown session by hand is an error");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_claude_hook_makes_its_card_resumable() {
        let st = test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = router(st.clone());
        tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
        });
        let i = id.clone();
        let code = tokio::task::spawn_blocking(move || {
            let e = Env {
                agent: Some("claude"),
                ..env(Some(&i), &url)
            };
            // The Stop hook: an explicit note, and the event on stdin.
            run(
                &args("needs_input --hook --if-not completed --note finished"),
                &e,
                &mut &br#"{"hook_event_name":"Stop","session_id":"s-1"}"#[..],
            )
        })
        .await
        .unwrap();
        assert_eq!(code, 0);
        let (note, resume): (Option<String>, Option<String>) = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT note, resume_input FROM sessions WHERE id = ?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(note.as_deref(), Some("finished"));
        assert_eq!(resume.as_deref(), Some("claude --resume s-1\r"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_stop_while_subagents_work_leaves_the_card_in_progress() {
        let st = test_state();
        let id = insert_session(&st.db.lock().unwrap(), None).unwrap().id;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = router(st.clone());
        tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
        });
        let i = id.clone();
        let code = tokio::task::spawn_blocking(move || {
            let e = env(Some(&i), &url);
            run(&args("in_progress --hook"), &e, &mut &b"{}"[..]);
            run(
                &args("needs_input --hook --if-not completed --note finished"),
                &e,
                &mut &br#"{"hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}"#[..],
            )
        })
        .await
        .unwrap();
        assert_eq!(code, 0);
        let status: String = st
            .db
            .lock()
            .unwrap()
            .query_row("SELECT status FROM sessions WHERE id = ?1", [&id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(status, "in_progress");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_hook_outside_a_terminal_finds_its_card_by_conversation() {
        let st = test_state();
        let session = crate::board::mint_session();
        let id = crate::sessions::store::insert_card(
            &st.db.lock().unwrap(),
            &crate::sessions::store::NewCard {
                agent_session: Some(&session),
                ..Default::default()
            },
        )
        .unwrap()
        .id;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = router(st.clone());
        tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
        });
        let s = session.clone();
        let (by_hand, hooked) = tokio::task::spawn_blocking(move || {
            let payload = format!(r#"{{"session_id":"ses_{s}"}}"#);
            let e = env(None, &url);
            let by_hand = set(&args("in_progress"), &e, &mut payload.as_bytes());
            let mut a = args("needs_input --hook --note waiting");
            a.push(payload);
            (by_hand, set(&a, &e, &mut &b""[..]))
        })
        .await
        .unwrap();
        assert!(
            by_hand.is_err(),
            "only a hook names its card by conversation"
        );
        assert_eq!(hooked, Ok(()));
        let (status, note): (String, Option<String>) = st
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT status, note FROM sessions WHERE id = ?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            (status.as_str(), note.as_deref()),
            ("needs_input", Some("waiting"))
        );
    }
}
