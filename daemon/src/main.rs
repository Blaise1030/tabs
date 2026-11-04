mod auth;
mod board;
mod chat;
mod cli;
mod error;
mod files;
mod sessions;
mod settings;
mod state;
#[cfg(test)]
mod test_support;
mod upload;
mod web;

use std::{
    net::SocketAddr,
    sync::{Arc, Mutex, atomic::Ordering},
};

use sessions::{FLUSH_INTERVAL, SHUTTING_DOWN, flush, open_db};
use state::{AppState, router};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(code) = cli::run(&args) {
        std::process::exit(code);
    }
    daemon();
}

#[tokio::main]
async fn daemon() {
    let port = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("PORT").ok())
        .unwrap_or_else(|| "7681".into());
    let host = std::env::var("HOST").unwrap_or_else(|_| "127.0.0.1".into());
    match bind_policy(
        &host,
        std::env::var("TABSH_ALLOW_INSECURE_BIND").is_ok_and(|v| v == "1"),
    ) {
        Ok(Some(warning)) => eprintln!("tabsh: WARNING: {warning}"),
        Ok(None) => {}
        Err(e) => {
            eprintln!("tabsh: {e}");
            std::process::exit(2);
        }
    }
    let addr = format!("{host}:{port}");

    let db_path = std::env::var("TABSH_DB").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        // The project was called webterm; carry its state (sessions, token,
        // uploads) over so existing tabs and paired browsers keep working.
        let (old, new) = (format!("{home}/.webterm"), format!("{home}/.tabsh"));
        if !std::path::Path::new(&new).exists() && std::path::Path::new(&old).is_dir() {
            match std::fs::rename(&old, &new) {
                Ok(()) => println!("tabsh: moved {old} to {new}"),
                Err(e) => eprintln!("tabsh: could not move {old} to {new}: {e}"),
            }
        }
        format!("{new}/state.db")
    });
    let db = open_db(&db_path).unwrap_or_else(|e| panic!("failed to open {db_path}: {e}"));
    let token_path = std::path::Path::new(&db_path).with_file_name("token");
    let token = auth::load_or_create_token(&token_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", token_path.display()));
    let origins: Vec<String> = match std::env::var("TABSH_ORIGINS") {
        Ok(list) => list
            .split(',')
            .map(|o| o.trim().trim_end_matches('/').to_owned())
            .filter(|o| !o.is_empty())
            .collect(),
        Err(_) => web::guard::HOSTED_ORIGINS
            .iter()
            .map(|o| o.to_string())
            .collect(),
    };
    let self_url = self_url(&host, &port);
    let port_number: u16 = port
        .parse()
        .unwrap_or_else(|e| panic!("invalid port {port}: {e}"));
    let state = AppState {
        db: Arc::new(Mutex::new(db)),
        live: Default::default(),
        starting: Default::default(),
        db_path: db_path.as_str().into(),
        started: std::time::Instant::now(),
        token: token.into(),
        origins: origins.into(),
        self_url: self_url.into(),
        events: tokio::sync::broadcast::channel(256).0,
        chats: chat::ChatManager::from_db_path(&db_path),
        port: port_number,
    };
    state
        .chats
        .bind_board(state.db.clone(), state.events.clone());
    state.chats.bind_url(&state.self_url);

    let flusher = state.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(FLUSH_INTERVAL);
            flush(&flusher);
        }
    });

    let app = router(state.clone());

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind {addr}: {e}"));
    println!("tabsh listening on http://{addr} (state: {db_path})");
    let local_host = match host.parse::<std::net::IpAddr>() {
        Ok(ip) if ip.is_loopback() || ip.is_unspecified() => web::guard::LOCAL_NAME.into(),
        _ => host.clone(),
    };
    println!(
        "tabsh listening on http://{addr} (Tabs API; open http://{local_host}:{port}/)"
    );

    tokio::select! {
        res = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()) => res.unwrap(),
        _ = shutdown_signal() => {
            SHUTTING_DOWN.store(true, Ordering::SeqCst);
            flush(&state);
            println!("tabsh: state saved, exiting");
            std::process::exit(0);
        }
    }
}

async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("install SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}

/// Whether binding `host` is allowed, and the warning to print when it
/// exposes the daemon beyond this machine. Binding every interface
/// (`0.0.0.0`/`::`) over plain HTTP is refused unless
/// `TABSH_ALLOW_INSECURE_BIND=1`. Tabs expects loopback only.
fn bind_policy(host: &str, allow_insecure: bool) -> Result<Option<String>, String> {
    if host.eq_ignore_ascii_case("localhost") {
        return Ok(None);
    }
    let Ok(ip) = host.parse::<std::net::IpAddr>() else {
        return Ok(Some(format!(
            "HOST={host} is not loopback; tabsh serves plain HTTP — bind 127.0.0.1"
        )));
    };
    if ip.is_loopback() {
        return Ok(None);
    }
    if ip.is_unspecified() && !allow_insecure {
        return Err(format!(
            "refusing to bind {host} (every interface) over plain HTTP; \
             set TABSH_ALLOW_INSECURE_BIND=1 to allow it, or bind 127.0.0.1"
        ));
    }
    Ok(Some(format!(
        "listening on {host} beyond this machine over plain HTTP — prefer 127.0.0.1"
    )))
}

/// Where shells (and `tabsh status`) reach the daemon: loopback when it
/// listens on every interface, and IPv6 literals in brackets.
fn self_url(host: &str, port: &str) -> String {
    let host = match host {
        "0.0.0.0" | "::" => "127.0.0.1",
        h => h,
    };
    if host.contains(':') && !host.starts_with('[') {
        format!("http://[{host}]:{port}")
    } else {
        format!("http://{host}:{port}")
    }
}

#[cfg(test)]
mod self_url_tests {
    use super::self_url;

    #[test]
    fn shells_reach_the_daemon_on_loopback() {
        assert_eq!(self_url("127.0.0.1", "7681"), "http://127.0.0.1:7681");
        assert_eq!(self_url("0.0.0.0", "7681"), "http://127.0.0.1:7681");
        assert_eq!(self_url("::", "7681"), "http://127.0.0.1:7681");
        assert_eq!(self_url("::1", "7681"), "http://[::1]:7681");
        assert_eq!(self_url("example.test", "1"), "http://example.test:1");
    }
}

#[cfg(test)]
mod bind_policy_tests {
    use super::bind_policy;

    #[test]
    fn loopback_binds_silently() {
        for host in ["127.0.0.1", "::1", "localhost", "LocalHost"] {
            assert_eq!(bind_policy(host, false), Ok(None), "{host}");
        }
    }

    #[test]
    fn every_interface_needs_the_explicit_opt_in() {
        for host in ["0.0.0.0", "::"] {
            assert!(bind_policy(host, false).is_err(), "{host}");
            assert!(bind_policy(host, true).unwrap().is_some(), "{host}");
        }
    }

    #[test]
    fn a_specific_remote_address_warns_but_binds() {
        assert!(bind_policy("192.168.1.2", false).unwrap().is_some());
        assert!(bind_policy("example.test", false).unwrap().is_some());
    }
}
