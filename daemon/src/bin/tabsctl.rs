//! Create and open Tabs sessions from a shell or agent.
//!
//! Speaks one JSON line to the browser's `agent.sock` (see TabshAgentSocket),
//! one line back. With `--card-only`, hits the bundled daemon's HTTP API and
//! opens no tab.

use serde_json::{Value, json};
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "\
usage:
  tabsctl new --terminal [--cwd DIR] [--name NAME] [--focus] [--json]
  tabsctl new --agent [--cwd DIR] [--prompt TEXT] [--provider NAME]
                      [--model ID] [--mode tui|ui] [--name NAME]
                      [--focus] [--json]
  tabsctl sessions [--json]
  tabsctl open SESSION_ID [--focus] [--json]
  tabsctl --help

Inside a Tabs session the browser is found with no setup: its socket sits in
the browser's own folder, and `TABSH_SESSION_ID` names the calling session so
the new tab lands beside it. Options:
  --card-only   create the card on the daemon only; open no tab
  --socket PATH speak to a different browser socket (tests)
Environment: TABSCTL_SOCKET overrides the socket path.
";

#[derive(Default)]
struct Options {
    json: bool,
    focus: bool,
    card_only: bool,
    socket: Option<String>,
    cwd: Option<String>,
    name: Option<String>,
    prompt: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    mode: Option<String>,
    kind: Option<String>,
    rest: Vec<String>,
}

fn main() -> ExitCode {
    match run(env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(fail) => {
            eprintln!("tabsctl: {}", fail.message);
            ExitCode::from(fail.code)
        }
    }
}

struct Failure {
    message: String,
    code: u8,
}

fn fail(code: u8, message: impl Into<String>) -> Failure {
    Failure {
        message: message.into(),
        code,
    }
}

fn run(args: Vec<String>) -> Result<(), Failure> {
    let Some(command) = args.first().map(String::as_str) else {
        print!("{USAGE}");
        return Ok(());
    };
    if matches!(command, "--help" | "-h") {
        print!("{USAGE}");
        return Ok(());
    }
    let options = parse(&args[1..])?;
    let parent = env::var("TABSH_SESSION_ID").unwrap_or_default();
    match command {
        "new" => {
            let kind = options
                .kind
                .clone()
                .unwrap_or_else(|| {
                    if options.prompt.is_some()
                        || options.provider.is_some()
                        || options.model.is_some()
                    {
                        "agent".into()
                    } else {
                        "terminal".into()
                    }
                });
            if let Some(mode) = &options.mode {
                if mode != "tui" && mode != "ui" {
                    return Err(fail(2, "--mode must be tui or ui"));
                }
            }
            if options.card_only {
                if !parent.is_empty() {
                    return Err(fail(
                        1,
                        "inside a Tabs session, omit --card-only so Tabs can ask before creating",
                    ));
                }
                print_answer(create_card_only(&kind, &options)?, &options);
                return Ok(());
            }
            let mut request = json!({
                "do": if kind == "agent" { "session.create.agent" } else { "session.create.terminal" },
                "focus": options.focus,
                "parent": parent,
            });
            if let Some(cwd) = &options.cwd {
                request["cwd"] = json!(cwd);
            }
            if let Some(name) = &options.name {
                request["name"] = json!(name);
            }
            if let Some(prompt) = &options.prompt {
                request["prompt"] = json!(prompt);
            } else if kind == "agent" && !options.rest.is_empty() {
                request["prompt"] = json!(options.rest.join(" "));
            }
            if let Some(provider) = &options.provider {
                request["provider"] = json!(provider);
            }
            if let Some(model) = &options.model {
                request["model"] = json!(model);
            }
            if let Some(mode) = &options.mode {
                request["mode"] = json!(mode);
            }
            print_answer(ask_browser(request, &options)?, &options);
        }
        "sessions" => {
            if options.card_only {
                return Err(fail(2, "sessions needs the browser; drop --card-only"));
            }
            print_answer(ask_browser(json!({ "do": "session.list" }), &options)?, &options);
        }
        "open" => {
            let id = options
                .rest
                .first()
                .ok_or_else(|| fail(2, "open needs a session id"))?;
            if options.card_only {
                return Err(fail(2, "open needs the browser; drop --card-only"));
            }
            print_answer(
                ask_browser(
                    json!({
                        "do": "session.open",
                        "session": id,
                        "focus": options.focus,
                        "parent": parent,
                    }),
                    &options,
                )?,
                &options,
            );
        }
        other => return Err(fail(2, format!("unknown command {other}\n\n{USAGE}"))),
    }
    Ok(())
}

fn parse(args: &[String]) -> Result<Options, Failure> {
    let mut out = Options::default();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        let take = |i: &mut usize, flag: &str| -> Result<String, Failure> {
            *i += 1;
            args.get(*i)
                .cloned()
                .ok_or_else(|| fail(2, format!("{flag} needs a value")))
        };
        match arg.as_str() {
            "--json" => out.json = true,
            "--focus" => out.focus = true,
            "--card-only" => out.card_only = true,
            "--terminal" => out.kind = Some("terminal".into()),
            "--agent" => out.kind = Some("agent".into()),
            "--cwd" => out.cwd = Some(take(&mut i, arg)?),
            "--name" => out.name = Some(take(&mut i, arg)?),
            "--prompt" => out.prompt = Some(take(&mut i, arg)?),
            "--provider" => out.provider = Some(take(&mut i, arg)?),
            "--model" => out.model = Some(take(&mut i, arg)?),
            "--mode" => out.mode = Some(take(&mut i, arg)?),
            "--socket" => out.socket = Some(take(&mut i, arg)?),
            _ if arg.starts_with("--") => {
                return Err(fail(2, format!("unknown option {arg}")));
            }
            _ => out.rest.push(arg.clone()),
        }
        i += 1;
    }
    Ok(out)
}

fn socket_path(options: &Options) -> PathBuf {
    if let Some(socket) = &options.socket {
        return PathBuf::from(socket);
    }
    if let Ok(env) = env::var("TABSCTL_SOCKET") {
        if !env.is_empty() {
            return PathBuf::from(env);
        }
    }
    if let Ok(db) = env::var("TABSH_DB") {
        if !db.is_empty() {
            // TABSH_DB/…/state.db → Application Support folder → agent.sock
            let folder = Path::new(&db)
                .parent()
                .and_then(|p| p.parent())
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from(&db));
            return folder.join("agent.sock");
        }
    }
    home_dir()
        .join("Library/Application Support/tabs-browser/agent.sock")
}

fn ask_browser(request: Value, options: &Options) -> Result<Value, Failure> {
    let path = socket_path(options);
    if !path.exists() {
        return Err(fail(
            1,
            format!(
                "Tabs isn't running (no socket at {}); open Tabs first, or use --card-only",
                path.display()
            ),
        ));
    }
    let mut stream = UnixStream::connect(&path).map_err(|_| {
        fail(
            1,
            format!(
                "Tabs isn't running (could not connect to {}); open Tabs first, or use --card-only",
                path.display()
            ),
        )
    })?;
    let mut line = serde_json::to_vec(&request).map_err(|e| fail(1, e.to_string()))?;
    line.push(b'\n');
    stream
        .write_all(&line)
        .map_err(|_| fail(1, "could not send the request to Tabs"))?;
    let mut data = Vec::new();
    let mut chunk = [0u8; 65536];
    while !data.contains(&b'\n') {
        let n = stream
            .read(&mut chunk)
            .map_err(|_| fail(1, "could not read from Tabs"))?;
        if n == 0 {
            break;
        }
        data.extend_from_slice(&chunk[..n]);
        if data.len() > 4_000_000 {
            return Err(fail(1, "Tabs sent too much back"));
        }
    }
    let object: Value =
        serde_json::from_slice(&data).map_err(|_| fail(1, "Tabs sent something unexpected"))?;
    if let Some(error) = object.get("error") {
        if let Some(message) = error.get("message").and_then(|m| m.as_str()) {
            return Err(fail(1, message.to_owned()));
        }
        if let Some(message) = error.as_str() {
            return Err(fail(1, message.to_owned()));
        }
        return Err(fail(1, "Tabs refused the request"));
    }
    Ok(object)
}

fn daemon_base() -> String {
    if let Ok(url) = env::var("TABSH_URL") {
        if !url.is_empty() {
            return url.trim_end_matches('/').to_owned();
        }
    }
    if let Ok(db) = env::var("TABSH_DB") {
        if db.contains("tabs-browser-dev") || db.contains("tabsh-browser-dev") {
            return "http://127.0.0.1:7683".into();
        }
        if db.contains("tabs-browser") || db.contains("tabsh-browser") {
            return "http://127.0.0.1:7682".into();
        }
    }
    "http://127.0.0.1:7681".into()
}

fn daemon_token() -> Option<String> {
    // Inside a card: never open the pairing token file. Session tokens are
    // not accepted for create/list HTTP calls; callers must use the socket.
    if env::var("TABSH_SESSION_ID")
        .ok()
        .is_some_and(|s| !s.is_empty())
    {
        return None;
    }
    let mut candidates = Vec::new();
    if let Ok(db) = env::var("TABSH_DB") {
        if !db.is_empty() {
            if let Some(dir) = Path::new(&db).parent() {
                candidates.push(dir.join("token"));
            }
        }
    }
    let home = home_dir();
    candidates.push(home.join("Library/Application Support/tabs-browser-dev/tabsh/token"));
    candidates.push(home.join("Library/Application Support/tabs-browser/tabsh/token"));
    candidates.push(home.join("Library/Application Support/tabsh-browser-dev/tabsh/token"));
    candidates.push(home.join("Library/Application Support/tabsh-browser/tabsh/token"));
    candidates.push(home.join(".tabsh/token"));
    for path in candidates {
        if let Ok(token) = std::fs::read_to_string(path) {
            let trimmed = token.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_owned());
            }
        }
    }
    None
}

fn daemon_request(method: &str, path: &str, body: Option<Value>) -> Result<Value, Failure> {
    let token = daemon_token().ok_or_else(|| fail(1, "no tabsh token found; is the daemon paired?"))?;
    let url = format!("{}{path}", daemon_base());
    let mut request = match method {
        "GET" => ureq::get(&url),
        "POST" => ureq::post(&url),
        "PATCH" => ureq::request("PATCH", &url),
        "PUT" => ureq::put(&url),
        "DELETE" => ureq::delete(&url),
        _ => return Err(fail(1, format!("bad method {method}"))),
    };
    request = request.set("Authorization", &format!("Bearer {token}"));
    let response = if let Some(body) = body {
        request
            .set("Content-Type", "application/json")
            .send_json(body)
    } else {
        request.call()
    }
    .map_err(|e| match e {
        ureq::Error::Status(code, _) => {
            fail(1, format!("the tabsh daemon refused the request ({code})"))
        }
        other => fail(1, format!("daemon request failed: {other}")),
    })?;
    let text = response
        .into_string()
        .map_err(|e| fail(1, e.to_string()))?;
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(&text).map_err(|e| fail(1, e.to_string()))
}

fn create_card_only(kind: &str, options: &Options) -> Result<Value, Failure> {
    let cwd = options
        .cwd
        .clone()
        .unwrap_or_else(|| home_dir().to_string_lossy().into_owned());
    if kind == "terminal" {
        let mut body = json!({ "cwd": cwd });
        if let Some(name) = &options.name {
            body["name"] = json!(name);
        }
        let made = daemon_request("POST", "/api/sessions", Some(body))?;
        let id = made
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| fail(1, "the daemon sent no session id"))?;
        return Ok(json!({ "session": id, "cardOnly": true }));
    }
    let settings = daemon_request("GET", "/api/settings", None).unwrap_or_else(|_| json!({}));
    let providers = settings
        .get("providers")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let wanted = options
        .provider
        .clone()
        .or_else(|| {
            settings
                .get("agentProvider")
                .and_then(|v| v.as_str())
                .map(str::to_owned)
        });
    let provider = providers
        .iter()
        .find(|p| p.get("name").and_then(|n| n.as_str()) == wanted.as_deref())
        .or_else(|| providers.first());
    let command = provider
        .and_then(|p| p.get("command"))
        .and_then(|c| c.as_str())
        .unwrap_or("claude {prompt}");
    let mode = options.mode.as_deref().unwrap_or("ui");
    let mut body = json!({
        "cwd": cwd,
        "prompt": options.prompt.as_deref().unwrap_or(""),
        "command": command,
        "resume": provider.and_then(|p| p.get("resume")).and_then(|r| r.as_str()).unwrap_or(""),
        "mode": mode,
    });
    if mode == "ui" {
        if let Some(acp) = provider
            .and_then(|p| p.get("acp"))
            .and_then(|a| a.as_str())
            .filter(|s| !s.is_empty())
        {
            body["acp_command"] = json!(acp);
        } else if provider.is_none() {
            body["acp_command"] = json!("npx --yes @agentclientprotocol/claude-agent-acp");
        }
    }
    if let Some(name) = &options.name {
        body["name"] = json!(name);
    }
    let made = daemon_request("POST", "/api/sessions", Some(body))?;
    let id = made
        .get("id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| fail(1, "the daemon sent no session id"))?
        .to_owned();
    let _ = daemon_request(
        "PATCH",
        &format!("/api/sessions/{id}/status"),
        Some(json!({ "status": "in_progress", "source": "user" })),
    );
    Ok(json!({ "session": id, "cardOnly": true }))
}

fn print_answer(answer: Value, options: &Options) {
    if options.json {
        if let Ok(text) = serde_json::to_string_pretty(&answer) {
            println!("{text}");
            return;
        }
    }
    if let Some(sessions) = answer.get("sessions").and_then(|v| v.as_array()) {
        for row in sessions {
            let id = row.get("id").and_then(|v| v.as_str()).unwrap_or("?");
            let status = row.get("status").and_then(|v| v.as_str()).unwrap_or("?");
            let name = row.get("name").and_then(|v| v.as_str()).unwrap_or("");
            println!("{id}  {status}  {name}");
        }
        return;
    }
    if let Some(session) = answer.get("session").and_then(|v| v.as_str()) {
        if answer.get("cardOnly").and_then(|v| v.as_bool()) == Some(true) {
            println!("created card {session} (no tab opened)");
        } else if let Some(tab) = answer.get("tab").and_then(|v| v.as_str()) {
            println!("created session {session} (tab {tab})");
        } else {
            println!("opened session {session}");
        }
    }
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}
