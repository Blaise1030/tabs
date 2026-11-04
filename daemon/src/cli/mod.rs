//! Subcommands on the daemon binary: `tabsh status` (agent hooks) and
//! `tabsh setup` (wire those hooks). Card create/list live in Tabs via tabsctl.

use std::io::IsTerminal;

mod daemon;
mod setup;
mod status;

const USAGE: &str = "usage:
  tabsh [port]                         start the daemon (default port 7681)
  tabsh status <status> [--note <text>] [--if-not <status>] [--hook [<json>]]
                                       set this terminal's card status:
                                       backlog, in_progress, needs_input, completed, archived
  tabsh setup                          print the guide a coding agent follows to keep
                                       its card current
  tabsh --version                      print the version";

/// Runs a subcommand and returns its exit code, or `None` when `args` means
/// "start the daemon".
pub(crate) fn run(args: &[String]) -> Option<i32> {
    match args.first().map(String::as_str) {
        Some("status") => {
            let mut stdin: Box<dyn std::io::Read> = if std::io::stdin().is_terminal() {
                Box::new(std::io::empty())
            } else {
                Box::new(std::io::stdin())
            };
            Some(status::run(
                &args[1..],
                &daemon::Env::from_process(),
                &mut stdin,
            ))
        }
        Some("setup") => Some(setup::run()),
        Some("--version" | "-V") => {
            println!("tabsh {}", env!("CARGO_PKG_VERSION"));
            Some(0)
        }
        Some("help" | "--help" | "-h") => {
            println!("{USAGE}");
            Some(0)
        }
        _ => None,
    }
}
