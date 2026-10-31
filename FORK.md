# tabsh-browser

A macOS WebKit browser with [tabsh](https://tabsh.cc) built in.

This repository is a fork of [driceroland/Search](https://github.com/driceroland/Search) (MIT,
see `LICENSE`). Search is the base: a small, quiet, native WebKit browser with sidebar tabs,
pins, groups, split view, find, downloads, passwords/passkeys, Reader and a signed updater.
The product goal here is different — the browser is the client for tabsh: cards, sessions and
agents live in the browser chrome, next to the pages they are working on.

Upstream is kept as a remote so fixes and features can be merged rather than rewritten:

```sh
git fetch upstream
git merge upstream/main
```

## Status

- Fork created from upstream `main` (`b122202`, 2026-10-30), full history.
- Bundle id is `cc.tabsh.browser` (`build.sh`), so a build here cannot share defaults,
  keychain items, WebKit containers or the updater with an installed Search.
- Session/history/passwords live in `~/Library/Application Support/tabsh-browser`.
- Upstream updates are **disabled** (`Updater.enabled` in `Sources/Search/Updater.swift`).
  Upstream's feed installs builds signed by Office Commun; enabling it would replace this app.
  Do not turn it back on until this fork has its own feed and signing identity.
- Nothing tabsh-specific is implemented yet.

## Building

Search needs the full Xcode 16 / Swift 6 toolchain (the Command Line Tools alone cannot build
it: `swift build` fails on the `SwiftUIMacros` plugin). This machine currently has only the
Command Line Tools, so the first step is installing Xcode and running
`sudo xcode-select -s /Applications/Xcode.app`.

```sh
swift build                 # run from the SwiftPM binary
SEARCH_DEV=1 ./build.sh     # a real .app in build/, named for the branch
./build.sh                  # release-style build, ad-hoc signed
```

Upstream's `CONTRIBUTING.md`, `README.md` and `docs` still describe Search and apply to code
inherited from it.

## Identity

Changed so far:

| Thing | Value |
| --- | --- |
| Bundle id (`build.sh`) | `cc.tabsh.browser` |
| App Support folder (`Store.folder`) | `tabsh-browser` |
| Updater | off |

Still to do once the product name is settled (all are string/branding passes, not
architecture):

- Product/display name (`NAME`/`SHOWN` in `build.sh`, menu strings, About, welcome screens).
- App icon (`Icon/` and `build.sh`), DMG background, site links.
- Default-browser name and the `http`/`https` handler registration.
- Passkeys: `Search.passkeys.entitlements` is tied to Office Commun's team
  (`7BYKA895MC.com.officecommun.search`); passkeys need this app's own Apple Developer team
  and application identifier.
- Updates: a feed, a Developer ID certificate and appcast signing of our own (or no updater
  at all for a personal build).
- AI add-on: the engine binary is verified as `com.officecommun.search.ai-engine` signed by
  Office Commun (`build.sh`, `AIEngine.swift`). The fork either ships no engine or signs its own.
- Keychain item service names (`com.officecommun.search.*`) and log subsystems — cosmetic,
  but worth aligning before a release so passwords don't look like another app's.

## tabsh integration

### What tabsh is

A Rust daemon on the machine plus an Astro/Solid web app. The daemon serves the app and the
API on `http://127.0.0.1:7681`, authenticated with a bearer token kept at
`~/.local/share/tabsh/token`. Its data lives beside the token
(`state.db`, `chats/`, `uploads/`).

Relevant API (all under the bearer token, see `~/Developer/tabsh/src/state.rs` for the full
list):

| Endpoint | Use |
| --- | --- |
| `GET /api/sessions` | Cards and their side terminals: id, name, status, folder, agent, tags, unread |
| `GET /api/board/events` | SSE: status changes (`source`: user or hook), session activity/bells, titles |
| `PATCH /api/sessions/{id}/status` | Move a card (Backlog / In progress / Needs input / Completed / Archived) |
| `PATCH /api/sessions/{id}/prompt` | Rename / change a card's prompt |
| `POST /api/sessions` | New card (folder, prompt, provider, status, tags) |
| `POST /api/uploads?name=` | Save a dropped/picked file, returns its path |
| `/api/files*` | Explorer: roots, listing, read/save, watch |
| `WS /ws?id=` | Terminal stream (the web app's xterm) |

### How the browser should use it

Two layers, in this order:

1. **Native chrome (the point of the fork).** A Swift client for the daemon in a new
   `Sources/Search/Tabsh/` folder: token discovery, a small HTTP/SSE client, and a sidebar
   section showing cards grouped by status across projects, with unread/bell state from
   `/api/board/events`. Cards open as tabs; their terminal is tabsh's web UI (`/app/`) or a
   future native terminal view, not a second PTY.
2. **Session tabs.** A tabsh session becomes a tab whose URL is the tabsh app for that session
   (`http://127.0.0.1:7681/app/?...`) so the terminal/chat is the web app's, with native tab
   status in the browser's own tab strip (badge, ring on Needs input).

Keep the daemon the source of truth. The browser is a client: no local card state that can
drift, no second SQLite, no polling when an SSE stream will do.

### Milestones

- **M0 — runnable fork.** Xcode installed, `SEARCH_DEV=1 ./build.sh` builds and launches,
  bundle id and data folder separate from Search. (blocked on Xcode)
- **M1 — tabsh sidebar.** Daemon discovery + token, card list grouped by status, live updates
  from `/api/board/events`, click opens the session, refresh/offline states.
- **M2 — sessions as tabs.** Opening a card makes/reuses a tab; tab title/status follow the
  card; Needs input rings/badges the browser tab and Dock.
- **M3 — capture.** "Send this page to tabsh": current URL + selection/title into a new card
  (folder picker, provider), images/attachments through `/api/uploads`.
- **M4 — board actions in the browser.** Move a card between statuses, new card, prompt edit,
  quick switcher (`⌘K`-style) over cards, all from native chrome.

Each milestone should be additive files where possible. Avoid editing `Browser.swift` and
`TabBar.swift` unless a seam is missing; those two files are where upstream moves fastest.

## Merge policy

- Track upstream `main`; merge it in at least monthly, and before starting a new milestone.
- Land small commits that a merge can reason about; no repo-wide reformatting.
- Prefer new files plus one registration line over rewrites of upstream files.
- Run `swift test` (and the app, ad hoc) after each merge.
- Upstream's own rules still apply to inherited code: no new dependencies, no analytics, no
  phone-home, WebKit only.

## Open decisions

1. Product name, display name and icon (the bundle id is a placeholder but a safe one).
2. M1 scope: full board in the sidebar, or sessions-only first.
3. Whether the terminal stays the tabsh web app or gets a native view later.
4. Public or private distribution, and the Apple Developer team for passkeys/signing.
