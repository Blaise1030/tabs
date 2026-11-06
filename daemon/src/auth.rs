//! Token authentication and generation for the daemon.

use axum::extract::Request;
use axum::http::header;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

/// Who a request's token belongs to.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Credential {
    /// The browser's pairing token: full daemon API.
    Main,
    /// A per-card token handed to that card's shell / ACP child: only that
    /// card's status hook, never settings, create, files, or approvals.
    Session { id: String },
}

/// The main bearer token, or nothing.
pub(crate) fn credential(expected: &str, presented: &str) -> Option<Credential> {
    token_eq(presented, expected).then_some(Credential::Main)
}

/// Whether this credential may call `method` `path`. Main may call
/// everything; a session token may only patch its own card status.
pub(crate) fn allows(credential: &Credential, method: &axum::http::Method, path: &str) -> bool {
    match credential {
        Credential::Main => true,
        Credential::Session { id } => {
            method == axum::http::Method::PATCH
                && path == format!("/api/sessions/{id}/status")
        }
    }
}

/// Reads the pairing token from `path`, creating it on first run. It is kept
/// across restarts so a paired browser stays paired.
pub(crate) fn load_or_create_token(path: &Path) -> std::io::Result<String> {
    // A creation race is settled by looping back to the existing-file
    // path, which validates whatever won.
    for _ in 0..3 {
        match open_token_file(path) {
            Ok(mut file) => {
                check_open_token_file(path, &file)?;
                let mut contents = String::new();
                file.seek(SeekFrom::Start(0))?;
                file.read_to_string(&mut contents)?;
                if contents.trim().len() >= 32 {
                    return Ok(contents.trim().to_owned());
                }
                // Too short to be a token: replace it through the same
                // descriptor that was just validated.
                let token = random_hex(32)?;
                file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
                file.seek(SeekFrom::Start(0))?;
                file.set_len(0)?;
                file.write_all(token.as_bytes())?;
                return Ok(token);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => match create_token_file(path) {
                Ok(token) => return Ok(token),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            },
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        format!(
            "token file {} kept appearing during creation",
            path.display()
        ),
    ))
}

/// Opens an existing token without following a symlink (`O_NOFOLLOW`),
/// so the descriptor validated below is the descriptor that is read and
/// written — the path is never re-resolved between check and use.
fn open_token_file(path: &Path) -> std::io::Result<std::fs::File> {
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    match opts.open(path) {
        Ok(file) => Ok(file),
        // A read-only token (e.g. mode 0400) cannot be opened for writing;
        // it can still be validated and read through a read-only descriptor.
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            let mut opts = std::fs::OpenOptions::new();
            opts.read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
            opts.open(path).map_err(|e| map_loop(path, e))
        }
        Err(e) => Err(map_loop(path, e)),
    }
}

fn create_token_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| map_loop(path, e))?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    let token = random_hex(32)?;
    file.write_all(token.as_bytes())?;
    Ok(token)
}

fn map_loop(path: &Path, e: std::io::Error) -> std::io::Error {
    if e.raw_os_error() == Some(libc::ELOOP) {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "token file {} is a symlink; remove it and restart",
                path.display()
            ),
        )
    } else {
        e
    }
}

/// An existing token is only trusted when the opened descriptor is a
/// regular file owned by this user. Loose permissions are repaired to
/// `0600` on that same descriptor rather than left readable by other
/// local users.
fn check_open_token_file(path: &Path, file: &std::fs::File) -> std::io::Result<()> {
    // `metadata` on a `File` is `fstat`: it describes the opened inode,
    // not whatever the path names now.
    let md = file.metadata()?;
    if !md.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("token file {} is not a regular file", path.display()),
        ));
    }
    if md.uid() != unsafe { libc::getuid() } {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("token file {} is not owned by this user", path.display()),
        ));
    }
    if md.permissions().mode() & 0o077 != 0 {
        eprintln!(
            "tabsh: tightening permissions on {} to 0600",
            path.display()
        );
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

pub(crate) fn random_hex(len: usize) -> std::io::Result<String> {
    let mut bytes = vec![0u8; len];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Compares in constant time so response timing doesn't leak the token.
pub(crate) fn token_eq(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0, |acc, (x, y)| acc | (x ^ y))
            == 0
}

/// `Authorization: Bearer <token>`, or `?token=` for WebSockets, which can't
/// set headers from a browser.
pub(crate) fn presented_token(req: &Request) -> Option<&str> {
    let bearer = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    bearer.or_else(|| {
        req.uri()
            .query()?
            .split('&')
            .find_map(|kv| kv.strip_prefix("token="))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("tabsh-auth-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn a_new_token_is_0600_and_round_trips() {
        let path = scratch("new").join("token");
        let token = load_or_create_token(&path).unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(mode(&path), 0o600);
        assert_eq!(load_or_create_token(&path).unwrap(), token);
    }

    #[test]
    fn loose_permissions_on_an_existing_token_are_repaired() {
        let dir = scratch("loose");
        let path = dir.join("token");
        let token = "a".repeat(64);
        std::fs::write(&path, &token).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(load_or_create_token(&path).unwrap(), token);
        assert_eq!(mode(&path), 0o600);
    }

    #[test]
    fn a_symlinked_token_is_refused() {
        let dir = scratch("symlink");
        let real = dir.join("real");
        std::fs::write(&real, "a".repeat(64)).unwrap();
        let path = dir.join("token");
        std::os::unix::fs::symlink(&real, &path).unwrap();
        assert_eq!(
            load_or_create_token(&path).unwrap_err().kind(),
            std::io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn a_symlink_substitution_never_reaches_its_target() {
        // What a path swapped in after any pathname check would point at:
        // opening with O_NOFOLLOW refuses it, and the target is untouched.
        let dir = scratch("substitution");
        let real = dir.join("real");
        let secret = "b".repeat(64);
        std::fs::write(&real, &secret).unwrap();
        let path = dir.join("token");
        std::os::unix::fs::symlink(&real, &path).unwrap();
        assert!(load_or_create_token(&path).is_err());
        assert_eq!(std::fs::read_to_string(&real).unwrap(), secret);
        assert!(
            std::fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn a_directory_is_not_a_token() {
        let path = scratch("directory");
        assert!(load_or_create_token(&path).is_err());
    }

    #[test]
    fn a_read_only_token_still_loads() {
        let dir = scratch("readonly");
        let path = dir.join("token");
        let token = "c".repeat(64);
        std::fs::write(&path, &token).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert_eq!(load_or_create_token(&path).unwrap(), token);
    }

    #[test]
    fn a_short_existing_token_is_replaced_at_0600() {
        let dir = scratch("short");
        let path = dir.join("token");
        std::fs::write(&path, "short").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let token = load_or_create_token(&path).unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(mode(&path), 0o600);
    }

    #[test]
    fn a_session_credential_is_limited_to_its_status_route() {
        let session = Credential::Session {
            id: "abc-1".into(),
        };
        assert!(allows(
            &session,
            &axum::http::Method::PATCH,
            "/api/sessions/abc-1/status"
        ));
        assert!(!allows(
            &session,
            &axum::http::Method::PATCH,
            "/api/sessions/other/status"
        ));
        assert!(!allows(
            &session,
            &axum::http::Method::GET,
            "/api/sessions/abc-1/status"
        ));
        assert!(!allows(&session, &axum::http::Method::POST, "/api/sessions"));
        assert!(allows(
            &Credential::Main,
            &axum::http::Method::POST,
            "/api/sessions"
        ));
    }
}
