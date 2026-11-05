# Vendored daemon (Tabs API daemon + tabsctl)

Stripped fork of [Blaise1030/tabsh](https://github.com/Blaise1030/tabsh) **v1.8.3**
for bundling inside Tabs. Only what the native browser needs.

**Kept:** sessions/PTY/WS, board + hooks (`tabsh status` / `setup`), ACP chat,
explorer (tree / folders / watch), settings, uploads, loopback auth guard,
`tabsctl` (create / list / open sessions via the browser socket or `--card-only`).

**Removed:** embedded web UI, sounds/PWA, Tailscale / multi-device remote,
`/api/performance`, file editor APIs, `tabsh new`/`list` (use `tabsctl`).

```sh
cargo build --release --locked --manifest-path daemon/Cargo.toml
```

Produces `daemon/target/release/tabsh` and `daemon/target/release/tabsctl`.
