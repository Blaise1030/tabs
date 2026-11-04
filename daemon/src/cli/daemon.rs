//! How the subcommands reach the daemon: where it is, its token, and a
//! one-shot request over a plain socket.

use std::{
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};

const TIMEOUT: Duration = Duration::from_millis(500);

/// What the subcommands read from their surroundings.
pub(super) struct Env {
    pub(super) session: Option<String>,
    pub(super) url: String,
    pub(super) token: Option<String>,
    /// The agent whose hook this is, when it says so in the environment
    /// (Claude Code sets `CLAUDECODE=1` for everything it runs).
    pub(super) agent: Option<&'static str>,
    /// The calling agent's conversation, which `tabsh new --fork` forks
    /// (Claude Code's `CLAUDE_CODE_SESSION_ID`).
    pub(super) conversation: Option<String>,
}

impl Env {
    pub(super) fn from_process() -> Env {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        // The token sits next to the state database, as the daemon keeps it.
        let token_path = match var("TABSH_DB") {
            Some(db) => std::path::Path::new(&db).with_file_name("token"),
            None => std::path::Path::new(&var("HOME").unwrap_or_else(|| ".".into()))
                .join(".tabsh/token"),
        };
        Env {
            session: var("TABSH_SESSION_ID"),
            url: var("TABSH_URL").unwrap_or_else(|| "http://127.0.0.1:7681".into()),
            token: std::fs::read_to_string(token_path)
                .ok()
                .map(|t| t.trim().to_owned()),
            agent: (var("CLAUDECODE").as_deref() == Some("1")).then_some("claude"),
            conversation: var("CLAUDE_CODE_SESSION_ID"),
        }
    }
}

/// The daemon's answer: its status code and body.
pub(super) struct Answer {
    pub(super) code: u16,
    pub(super) body: String,
}

/// A one-shot HTTP/1.1 request over a plain socket: the daemon is on
/// loopback and this keeps the binary free of an HTTP client crate.
pub(super) fn request(
    env: &Env,
    method: &str,
    path: &str,
    body: Option<&str>,
) -> Result<Answer, String> {
    let url = &env.url;
    let authority = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("TABSH_URL must start with http:// (got '{url}')"))?
        .split('/')
        .next()
        .unwrap_or_default();
    let unreachable = |e: std::io::Error| format!("can't reach the tabsh daemon at {url}: {e}");
    let addr = authority
        .to_socket_addrs()
        .map_err(unreachable)?
        .next()
        .ok_or_else(|| format!("can't resolve {authority}"))?;
    let mut stream = TcpStream::connect_timeout(&addr, TIMEOUT).map_err(unreachable)?;
    stream
        .set_read_timeout(Some(TIMEOUT))
        .map_err(unreachable)?;
    stream
        .set_write_timeout(Some(TIMEOUT))
        .map_err(unreachable)?;
    let auth = env
        .token
        .as_deref()
        .map(|t| format!("Authorization: Bearer {t}\r\n"))
        .unwrap_or_default();
    let body = body.unwrap_or_default();
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: {authority}\r\n{auth}\
         Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .map_err(unreachable)?;
    let mut answer = Vec::new();
    stream.read_to_end(&mut answer).map_err(unreachable)?;
    let odd = || "the daemon sent an odd answer".to_owned();
    let code = answer
        .get(9..12) // "HTTP/1.1 200"
        .and_then(|c| std::str::from_utf8(c).ok())
        .and_then(|c| c.parse().ok())
        .ok_or_else(odd)?;
    let text = String::from_utf8_lossy(&answer);
    let (_, body) = text.split_once("\r\n\r\n").ok_or_else(odd)?;
    Ok(Answer {
        code,
        body: body.to_owned(),
    })
}
