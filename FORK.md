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
it: `swift build` fails on the `SwiftUIMacros` plugin). Xcode 27.2 is installed and selected
on this machine (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`).

Xcode's license has to be agreed once before its tools will build anything:

```sh
sudo xcodebuild -license accept
```

Then:

```sh
swift build                 # run from the SwiftPM binary
SEARCH_DEV=1 ./build.sh     # a real .app in build/, named for the branch
./build.sh                  # release-style build, ad-hoc signed
```

### On GitHub Actions

`.github/workflows/build.yml` builds the app where there is no Xcode-licensed Mac to hand: it
builds the daemon from the vendored tree in [`tabsh/`](tabsh/) (from
[Blaise1030/tabsh](https://github.com/Blaise1030/tabsh) — see [`tabsh/VENDOR.md`](tabsh/VENDOR.md)),
and passes the binary to `build.sh` as `TABSH_BINARY`, so the download carries terminals and
agents with it.

- **Actions → Build → Run workflow** builds without releasing and leaves `Tabs.zip` and
  `Tabs.dmg` as run artifacts. Pick one architecture to halve the runner minutes (macOS bills at
  10x on a private repository).
- **Push a `v*` tag** builds both architectures and attaches `Tabs-<version>-arm64.zip/.dmg` and
  `Tabs-<version>-x86_64.zip/.dmg` to a published release. A hand-started release is a draft.

Builds are ad-hoc signed, not notarised. A download on another Mac needs the quarantine flag off
once — `xattr -dr com.apple.quarantine /Applications/Tabs.app`, or right-click → Open — and then
starts normally. The release notes say the same.

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

- ~~Product/display name~~ Done: the browser is **Tabs** (`NAME="Tabs"` in `build.sh`, `Tabs.app`, menu/About/welcome strings). Release builds keep bundle id `cc.tabsh.browser` and data folder `tabsh-browser` (daemon port 7682). `SEARCH_DEV=1` builds are fully isolated: `cc.tabsh.browser.dev`, `tabsh-browser-dev`, daemon port 7683.
- ~~App icon~~ Done: globe-in-capsule mark from `Icon/mark.svg` (Dock via `Icon/icon.swift`, in-app via `Design.swift` `Logomark`). DMG background says Tabs. Site links still to do.
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
`~/.tabsh/token`. Its data lives beside the token
(`state.db`, `chats/`, `uploads/`).

**The browser runs its own instance.** It starts the bundled `tabsh` with `TABSH_DB` under
`~/Library/Application Support/tabsh-browser/tabsh/` (database, token, `chats/` and
`uploads/` all beside it) and `PORT=7682`, and only adopts a daemon whose `/api/about`
reports that database. A tabsh serving the web app, the CLI or a phone on 7681 is left
alone: the two never share a database, a token or a card list. The shells it starts inherit
`TABSH_DB`, so `tabsh status` in an agent's hook reports to the browser's instance too,
whichever `tabsh` binary is on `PATH`. See `TabshDaemon.swift`.

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

### Implementation notes (browser side)

Seams found in the fork, to keep the change small:

- **Tabs are URLs already.** `Browser.open(_:foreground:atEnd:from:mayWait:)`
  (`Sources/Search/Browser.swift:4709`) creates a tab from a URL, and the session restores
  tabs by URL (`Sources/Search/Session.swift`). A solo session URL therefore survives a
  restart with no new persistence.
- **One tab per session.** Dedupe by scanning `tabs + parkedTabs` for a tab whose URL matches
  `solo=1` and the same `tab=<id>`; activate it instead of opening a second one.
- **Pairing once.** The token lives at `~/.tabsh/token` (mode 0600). The browser
  reads it and opens `http://127.0.0.1:7681/open?token=…` once per install; the daemon stores
  it in that origin's `localStorage`, which the session tabs share. Swift calls to
  `/api/…` use the same token as `Authorization: Bearer …`.
- **Loading from the daemon, not tabsh.cc.** `http://127.0.0.1:7681/app/…` avoids WebKit's
  https→http loopback restriction and gives the tabs a single, stable origin.
- **Status later.** Keep a `[sessionID: Tab]` index built from the tab URLs; `/api/board/events`
  then updates a badge/title without touching the tab model. `Tab` is
  `Sources/Search/Tab.swift:270`; the switcher is `TabSwitcher.swift` (⌘K).
- **New code goes in `Sources/Search/Tabsh/`**: token discovery, the tiny HTTP/SSE client,
  solo URL building/parsing, and the switcher rows. One registration line in the app, no
  edits to `Browser.swift` beyond what the switcher needs.

### Split screen

Search already has the split: any two tabs side by side (or stacked), one draggable divider,
the focused pane outlined, with pairs and widths restored (`TabSplit`/`SplitView`). Session
tabs inherit it for free, which gives the package the pairing that matters without a second
layout system:

- a session terminal beside the page it is building, or beside the docs;
- two sessions, e.g. an agent working while you watch another;
- a session beside the board tab.

No tabsh-side split is needed in solo mode: the browser's split is the only one. Later, add
"Open Session Beside This Page" (split the current page with a session).

### One package

The goal is one `.app` the user installs and opens: browser, split, session tabs, terminal and
agent chat. The tabsh **daemon** is the one external piece:

- **Ship the daemon inside the bundle** (done): a signed `tabsh` binary in
  `Contents/Resources/`, started at launch if this browser's instance is not already up.
- **Its own state** (done): `TABSH_DB` and `PORT` point it at
  `~/Library/Application Support/tabsh-browser/tabsh/` and port 7682. It never adopts the
  user's daemon on 7681 and never touches `~/.tabsh`; see `TabshDaemon.swift`. Starting
  fresh means the browser's cards and the web app's cards are separate lists.
- **It outlives the app on purpose**: tabsh's promise is that shells stay up when the tab,
  the window and the app go away, so quitting the browser does not stop it. A later launch
  reuses it.
- **`tabsctl`, a session CLI of the browser's own** (done): a separate signed binary in
  `Contents/Resources/` (`Sources/TabsCLI/`, a SwiftPM executable next to `Search` — not
  part of the tabsh repo), linked beside `tabsh` in the daemon's `bin` folder so an agent
  in any session shell finds it on `PATH`. `tabsctl new --agent --prompt …` /
  `tabsctl new --terminal` speaks one JSON line to the browser's `agent.sock`
  (`TabshAgentSocket.swift`, uid-checked, sessions only — not the bench), the browser
  creates the session through the composer's own paths and opens its tab in the
  background (`--focus` to select it); `tabsctl sessions` and `tabsctl open <id>` list
  and reopen. With Tabs not running it fails rather than leaving an orphan card;
  `--card-only` creates the card on the daemon directly.

Packaging concerns still to settle: signing/notarizing the embedded daemon as a helper,
updating it with the app through the same signed feed, the extra binary size, and offering
"Open tabsh in another browser" as a fallback. The daemon embeds the web app, so no
separate web assets are needed beyond the binary.

### Dictation

Voice for the two places a prompt is written here, both on this Mac and
nowhere else: the New Agent card has a mic beside the attach button, and a
session terminal takes `Edit › Dictate` (⌥⌘D) — what settles is typed into
the shell for you to fix or send, never run.

`Sources/Search/Dictation.swift` holds both engines: macOS 26's
`DictationTranscriber`, and `SFSpeechRecognizer` with
`requiresOnDeviceRecognition` on 14–25. A Mac whose language cannot recognise
offline says so instead of sending audio to a server. A pill at the foot of
the screen shows what is still being revised and never takes the keyboard;
Return keeps what was said, Escape throws it away. `build.sh` carries the
speech usage sentence for the older engine.

### Working on the tabsh side

The solo view is a change to the tabsh repo (`~/Developer/tabsh`), which has its own rules:
`docs/architecture.md`, one feature per folder, pure logic tested with `node --test`, and
`pnpm -C web test` / `pnpm -C web check`. Do it in a session rooted there rather than mixing
both repositories in one diff.

### Milestones

- **M0 — runnable fork.** `./build.sh` builds and launches, bundle id and data folder separate
  from Search. (needs the Xcode license agreed; see below)
- **M1 — solo session view (tabsh repo).** `?solo=1&tab=<id>` renders one terminal or agent
  chat with no tabsh chrome, with tests for the place parsing and the shell rendering.
- **M2 — session tabs.** Browser opens a solo URL as a normal tab, one per session, restores
  them on launch, titles from the daemon, close just closes the tab. Split works between a
  session tab and any other tab.
- **M3 — switcher.** `⌘K` lists tabsh cards across projects with status; Enter opens/focuses
  the tab; "New session" creates a card and opens its tab.
- **M4 — live status.** Needs-input/completed badges and Dock/tab attention from
  `/api/board/events`; status changes from the tab's context menu.
- **M5 — capture.** "Send this page to tabsh": current URL + selection/title into a new card.
- **M6 — one package.** Embed the daemon in the app bundle (or reuse an installed one),
  signed and updated with the app.

Each milestone should be additive files where possible. Avoid editing `Browser.swift` and
`TabBar.swift` unless a seam is missing; those two files are where upstream moves fastest.

## Merge policy

- Track upstream `main`; merge it in at least monthly, and before starting a new milestone.
- **Automated:** `.github/workflows/sync-upstream.yml` runs every Monday (and on demand). It
  merges `driceroland/Search` `main` into `chore/sync-upstream` and opens a PR, or files an
  `upstream-sync` issue on conflict. Review that PR; never auto-merge it. Enable
  Settings → Actions → General → “Allow GitHub Actions to create and approve pull requests”
  so the bot can open the PR.
- **Dependencies:** `.github/dependabot.yml` watches SwiftPM (root), `site/` (npm), `tabsh/`
  (Cargo), and GitHub Actions. Turn on Dependabot alerts + security updates under
  Settings → Code security (off by default on a private repo).
- Land small commits that a merge can reason about; no repo-wide reformatting.
- Prefer new files plus one registration line over rewrites of upstream files.
- Run `swift test` (and a quick ad-hoc launch) after each merge.
- Upstream's own rules still apply to inherited code: no new dependencies, no analytics, no
  phone-home, WebKit only.

## Open decisions

1. ~~Product name and display name: **Tabs**.~~ ~~Icon~~ Done (globe-in-capsule mark).
2. Does the board exist anywhere in the browser, or is the switcher enough? Recommended: one
   optional "tabsh" tab for the full board, everything else session tabs.
3. Are session tabs pinned by default, or grouped under a "tabsh" group?
4. Whether the terminal stays the tabsh web app in a tab or gets a native view later (start
   with the web app; it is the same xterm and chat the daemon already serves).
5. Public or private distribution, and the Apple Developer team for passkeys/signing.
