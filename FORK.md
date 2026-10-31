# tabsh-browser

A macOS WebKit browser with [tabsh](https://tabsh.cc) built in.

This repository is a fork of [driceroland/Search](https://github.com/driceroland/Search) (MIT,
see `LICENSE`). Search is the base: a small, quiet, native WebKit browser with sidebar tabs,
pins, groups, split view, find, downloads, passwords/passkeys, Reader and a signed updater.
The product goal here is different: **a tabsh session is a browser tab.** The terminal and
the agent chat are what a tabsh tab shows, in the browser's own tab strip — no second tab
strip, no board required to work.

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

**One tabsh session = one browser tab.** The browser's tab strip is the only tab strip; the
terminal or the agent chat fills the tab's content. Closing the tab does not kill the shell
(tabsh's whole point is that sessions outlive tabs); reopening it reattaches.

Two pieces make that work:

1. **A solo session view in the tabsh web app** (separate, small change in
   `~/Developer/tabsh`). A URL such as `http://127.0.0.1:7681/app/?solo=1&tab=<id>` that:
   - forces the place to that session,
   - hides the board, the tab strip, the session bar and the explorer,
   - keeps the terminal/chat attach, reconnect and title behaviour as they are today.

   Without this, every tab would show a second tab strip and the board inside it. Do that
   work in the tabsh repo under its own rules (`docs/architecture.md`, pure logic tested with
   `node --test`, one feature per folder).

2. **Native session tabs in the browser.**
   - A tab whose URL is the solo session URL above; the session id is part of the tab so a
     restart restores it.
   - Opening a session: a switcher (`⌘K`-style) listing cards across projects from
     `GET /api/sessions`, Enter opens or focuses the one tab per session (no duplicates).
   - Tab title from the card's name/agent title; live status (Needs input, Completed) from
     `GET /api/board/events`, shown as a badge/ring on the tab.
   - Close = close the tab, not the shell. A closed tab can be reopened from the switcher.
   - Later: status actions in the tab's context menu, "new session", and "send this page to
     tabsh" (URL/selection into a card, attachments through `/api/uploads`).

The daemon stays the source of truth. The browser keeps tab identity and presentation only;
no local card database, no polling when SSE will do.

### Milestones

- **M0 — runnable fork.** Xcode installed, `SEARCH_DEV=1 ./build.sh` builds and launches,
  bundle id and data folder separate from Search. (blocked on Xcode)
- **M1 — solo session view (tabsh repo).** `?solo=1&tab=<id>` renders one terminal or agent
  chat with no tabsh chrome, with tests for the place parsing and the shell rendering.
- **M2 — session tabs.** Browser opens a solo URL as a normal tab, one per session, restores
  them on launch, titles from the daemon, close just closes the tab.
- **M3 — switcher.** `⌘K` lists tabsh cards across projects with status; Enter opens/focuses
  the tab; "New session" creates a card and opens its tab.
- **M4 — live status.** Needs-input/completed badges and Dock/tab attention from
  `/api/board/events`; status changes from the tab's context menu.
- **M5 — capture.** "Send this page to tabsh": current URL + selection/title into a new card.

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
2. Does the board exist anywhere in the browser, or is the switcher enough? Recommended: one
   optional "tabsh" tab for the full board, everything else session tabs.
3. Are session tabs pinned by default, or grouped under a "tabsh" group?
4. Whether the terminal stays the tabsh web app in a tab or gets a native view later (start
   with the web app; it is the same xterm and chat the daemon already serves).
5. Public or private distribution, and the Apple Developer team for passkeys/signing.
