# browser.tabsh.cc — marketing site plan

A one-page marketing site for **Tabs**, the macOS browser with tabsh inside it, at
`https://browser.tabsh.cc`. Modelled on [searchbrowser.app](https://searchbrowser.app/):
editorial, quiet, one long scroll, screenshots with captions, declarative copy, a
measured-numbers section, and a short FAQ. Not a docs site and not an app.

Decisions already made:

- **Lives in this repo**, in `site/`, deployed as its own Cloudflare Worker on
  `browser.tabsh.cc`.
- **Downloads** point at stable aliases on GitHub Releases.
- **One long landing page**, no separate download/changelog pages in v1.
- **Visual direction**: Search editorial, not the tabsh.cc terminal/ASCII look.

---

## 1. Goal

Someone lands, understands in one screen that this is a small, fast Mac browser whose
tabs can be terminals and agent sessions, and downloads it without reading a manual.

Non-goals for v1: docs, blog, changelog page, app demo, pricing, accounts, analytics,
cookies, newsletter. The site says one thing, shows it, and gets out of the way.

Audience: people who already use tabsh and want the browser, plus Mac users who want a
light WebKit browser and are curious about the agent-tab idea.

---

## 2. Positioning

**One line:** Tabs is a browser for the Mac with tabsh built in — a session is a tab.

**The three claims, in order:**

1. **A real browser.** Native WebKit, small, fast, tabs across the top or down the side,
   pins, spaces, reading mode, ad blocking, keychain passwords, extensions.
2. **A session is a tab.** The terminal and the agent chat live in the browser's own tab
   strip. Close the tab; the shell keeps running. Reopen it; it reattaches. No board
   required, no second tab strip.
3. **One package.** The tabsh daemon ships inside the app. Install Tabs, open it, and the
   shells are there. Agents are still the CLIs already on the Mac (`claude`, `codex`,
   `opencode`).

**Tone:** plain, specific, unhurried. Short sentences. No "revolutionary", no "AI-powered",
no exclamation marks. Prefer a number to an adjective, but only publish numbers we have
measured (see §8).

---

## 3. Page outline and draft copy

A single `index.astro`. Sections in this order:

### 3.1 Masthead (thin, non-sticky)

```
Tabs                                    tabsh.cc · GitHub · Download
```

Small wordmark with the globe-in-capsule mark. Right side: `tabsh.cc`, `GitHub`,
`Download` (the last one filled/pill).

### 3.2 Hero

```
Tabs is a browser for the Mac with tabsh inside it.
A session is a tab — the terminal and the agent chat sit in the
tab strip you already use. WebKit, [X] megabytes, free for macOS 14 or later.

[ Download for macOS ]   [ The numbers ↓ ]

Version 1.1.5 · 12.1 MB · Free · Intel Mac?
```

Rules:

- First sentence must survive being read alone.
- The download button is the only filled control above the fold.
- Version/size line is generated from `site/src/site.ts` (see §7.4).

### 3.3 Figure 1 — the product itself

Large screenshot, light and dark variants, caption in the Search style:

> **fig. 1** The browser with a session tab: a shell on the left of the tab row, the page
> it is building on the right.

This is the single most important asset. It must show one ordinary-looking browser tab
that happens to contain a terminal, plus a normal page beside it. No fake chrome, no
marketing frame.

### 3.4 "A session is a tab"

Prose + screenshot of the tab strip and a solo session.

- One tab per session. Open it again and it is the same shell, not a copy.
- Closing the tab does not kill the shell. Quitting the browser does not either.
- Titles come from the card; the tab carries its status (needs input, done).
- No duplicate tabs for the same session.

### 3.5 "Split, when you need it"

Prose + screenshot of a session beside the page it is working on.

- Any two tabs side by side or stacked, one divider, widths restored.
- A session beside the page it builds, the docs, or another session.
- The browser's split is the only split; solo session tabs carry no tabsh chrome.

### 3.6 "A quiet browser underneath"

Two-column list of inherited Search features, each one line. Candidate entries:

- Tabs across the top or down the side (`⇧⌘S`), and a sidebar that folds away (`⌘S`).
- Pins that shrink to a letter or an icon.
- Spaces: separate sets of tabs, each with its own icon.
- Reading mode (`⇧⌘R`).
- An ad blocker that runs before the page, in the network layer.
- Hide anything, per site, before it draws (`⇧⌘H`).
- Floating video that follows you above every app (`⇧⌘P`).
- Passwords and passkeys in the macOS keychain.
- Chrome extensions on WebKit's own extension engine (macOS 15.4+).
- Private tabs with their own cookie jar (`⇧⌘N`).
- One field: address, search, history, and answers from the keychain.
- No sync, no account, no telemetry. Everything stays on the Mac.

Do not claim features the fork has disabled or not yet wired (auto-update, passkeys
under our own team, default-browser registration). See §10.

### 3.7 "Light enough to forget it's there" (optional in v1)

Search publishes a measured table with bars (disk, first window, memory, processes).
Only include this section if we can measure Tabs honestly; otherwise use a single
verified line ("about [X] MB on disk") and leave the section out.

If included: medians of three runs, same Mac, method linked, bars drawn with CSS (no
chart library). Keep the numbers in `site/src/numbers.ts` with a `measured` date.

### 3.8 "One package" / install

Short block:

1. Download the `.dmg` (Apple silicon or Intel).
2. Drag Tabs to Applications.
3. First launch on another Mac: ad-hoc signed build, so right-click → Open, or clear the
   quarantine flag. Link the exact command.

Also: the tabsh daemon is inside; agents are the CLIs on `PATH`; nothing else to install.

### 3.9 FAQ

Keep to questions a visitor actually arrives with:

- What is Tabs? (A fork of Search with tabsh integrated.)
- How is this different from opening tabsh.cc in Safari? (One tab strip; a session is a
  tab; the daemon is local and bundled.)
- Do I need tabsh installed separately? (No.)
- Is it Chromium? (No — WebKit, the engine in macOS.)
- Is it free? (Yes.)
- Which Macs? (macOS 14+, Apple silicon or Intel.)
- Do my agents work? (Yes, if their CLI is on `PATH`.)
- Does it sync? (No.)
- Where do updates come from? (Not yet; the upstream feed is off. Updates will be manual
  until this fork has its own signed feed.)
- Is it open source? (Yes, MIT, fork of `driceroland/Search`; link `FORK.md`.)
- Something's wrong? (GitHub issues / mail.)

### 3.10 Footer

Download again, then: `tabsh.cc` · `GitHub` · `Changelog` · `FORK.md` · `Privacy`.
One line: "Tabs is made by Blaise. Built on Search by Office Commun." Keep the upstream
attribution required by the MIT license.

---

## 4. Visual system

Borrowed structurally from searchbrowser.app, not copied. Tokens adapted from its
stylesheet:

```css
--ink: #171717;
--ink-2: rgba(23, 23, 23, .5);
--ink-3: rgba(23, 23, 23, .36);
--ink-4: rgba(23, 23, 23, .2);
--ground: #fff;
--wash: #f3f3f2;
--pill: #ececec;
--hair: rgba(23, 23, 23, .09);

--max-w: 1280px;
--page-pad: 24px;
--radius: 18px;
--glide: cubic-bezier(.22, 1, .36, 1);
```

- **Type:** Inter 400/500/600, self-hosted (`site/public/fonts/`) so the page makes no
  third-party requests. System fallback stack identical to Search's.
- **Scale:** one big hero sentence (~clamp 40–64px), section headings ~28–36px, body
  ~18px, captions/meta 12–13px. Generous line-height (1.5–1.6), tight heading leading.
- **Layout:** single column max 1280px, asymmetric editorial margins, thin hairline
  rules, figures full-bleed inside the column with small captions.
- **Color:** near-black on white; one warm accent only if needed (Search uses a single
  orange-ish highlight). Dark mode via `prefers-color-scheme`, same tokens inverted.
- **Motion:** one reveal on screenshots (fade/translate 8px), no parallax, no scroll
  libraries. Respect `prefers-reduced-motion`.
- **Controls:** black pill for the primary download, hairline outline for secondary.
  `:focus-visible` ring everywhere.
- **No** gradients-as-decoration, glassmorphism, device mockups, stock photography, or
  icon grids.

---

## 5. Technical shape

Static Astro, no UI framework integrations, no Tailwind. Same deployment model as
`tabsh.cc` (Cloudflare Worker with static assets), but a separate Worker so the two
sites deploy independently.

```
site/
  astro.config.mjs        site: https://browser.tabsh.cc, output: static
  package.json            astro, @astrojs/check, wrangler
  tsconfig.json
  wrangler.jsonc          name: tabs-browser, assets: ./dist, route: browser.tabsh.cc
  public/
    favicon.svg           from Icon/mark.svg on a plate
    apple-touch-icon.png
    og.png                1200 × 630
    _headers              cache + security headers, immutable assets
    robots.txt
    sitemap.xml
    fonts/                Inter 400/500/600 woff2
    shots/                fig. 1–3, light + dark
  src/
    pages/index.astro     the whole page
    layouts/Page.astro    head, SEO, masthead, footer shell
    components/           Figure.astro, Download.astro, Faq.astro (only if reused)
    styles/site.css       tokens + layout + type
    site.ts               URL, repo, version, size, download URLs
    seo.ts                canonical/OG/JSON-LD helpers (adapted from tabsh web)
```

Notes:

- `output: 'static'`; no server code, no runtime API calls. Everything resolves at build.
- `astro check` and `biome` (or just `astro check`) in CI.
- One external dependency tree: Astro + Wrangler. Keep it that small.
- No analytics, no cookie banner, no fonts CDN, no client-side framework.
- A tiny inline script only if we detect Apple silicon vs Intel for the download button.
- Use `Astro.redirect`? No — static. Direct GitHub URLs instead (see §6).

### SEO and social

- `<title>`: "Tabs — a Mac browser with tabsh inside it".
- Meta description under 160 chars, matching the hero claim.
- Canonical `https://browser.tabsh.cc/`.
- OG/Twitter image `og.png` (1200×630) with the product screenshot and the one-liner.
- JSON-LD `SoftwareApplication` (`operatingSystem: macOS`, `offers: 0 USD`), adapted from
  `tabsh/web/src/seo.ts`.
- `robots.txt` with sitemap; `sitemap.xml` with the single URL.
- `_headers`: long cache for `/shots/*`, `/fonts/*`, `/_astro/*`; `nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, a CSP that allows only self.

---

## 6. Downloads and releases

The build workflow currently publishes versioned assets only
(`Tabs-<version>-arm64.dmg`, `Tabs-<version>-x86_64.dmg`, and zips). The site needs names
that never change.

**Change to `.github/workflows/build.yml` (release job):** after collecting `out/`, also
copy stable aliases into the release:

```
Tabs.dmg          -> same file as Tabs-<version>-arm64.dmg
Tabs.zip          -> same file as Tabs-<version>-arm64.zip
Tabs-intel.dmg    -> Tabs-<version>-x86_64.dmg
Tabs-intel.zip    -> Tabs-<version>-x86_64.zip
```

Then the site can link, permanently:

```
https://github.com/Blaise1030/tabs/releases/latest/download/Tabs.dmg
https://github.com/Blaise1030/tabs/releases/latest/download/Tabs-intel.dmg
```

`releases/latest/download/<name>` follows the latest non-draft release. If a release has
no Intel build, the Intel link 404s — acceptable in v1, but the FAQ should say Intel is
built when a release includes it, or the link should go to `/releases/latest` instead.

Why not host the DMG in the Worker: the app is ~24 MB uncompressed and the assets
pipeline is a poor fit for per-release binaries. GitHub Releases already carries them,
gives checksums, and costs nothing. R2 is the fallback if direct-download behaviour or
rate limits become a problem.

Version/size on the page:

- `site/src/site.ts` holds `VERSION` (from the repo's `VERSION` file at scaffold time) and
  `BYTES`/`MB` measured from the built DMG.
- v1: update these by hand in the release PR/commit.
- Later: a release step can rewrite `site.ts` (or write `site/src/release.json`) with the
  tag, size and date before deploying. Do not fetch GitHub at runtime.

---

## 7. Deployment

1. **Cloudflare Worker** `tabs-browser`, static assets plus one tiny Worker
   (`site/src/worker.ts`) that redirects plain HTTP to HTTPS.
   `wrangler.jsonc` with `routes: [{ pattern: "browser.tabsh.cc", custom_domain: true }]`.
   The `tabsh.cc` zone is already in the account, so the subdomain is a DNS/custom-domain
   entry, not a new zone.
2. **GitHub Actions** `.github/workflows/site.yml`:
   - on `push` to `main` with `paths: [site/**, .github/workflows/site.yml]`, and
     `workflow_dispatch`;
   - `npm ci`, `npm run check`, `npm run build`, then `npx wrangler deploy`;
   - guard on `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`, as `tabsh`'s release
     workflow does.
   - Set both secrets on the `tabs` repo (they can be the same values as the
     `tabsh` repo).
3. **First deploy**: run locally once with `npx wrangler deploy` to create the Worker and
   attach the custom domain, then let CI take over.
4. **Cross-links**: add a small "Get the browser" link on `tabsh.cc` (hero or footer),
   and link back to `tabsh.cc` from this site. Do that as a separate change in the tabsh
   repo, under its rules.
5. **Cache**: Cloudflare handles HTML revalidation; hashed `_astro` assets are immutable.
6. **Preview**: `npm run dev` locally; optional `wrangler versions upload` for a preview
   URL if wanted later.

No DNS work beyond adding the custom domain in Cloudflare, assuming `tabsh.cc` stays in
the same account.

---

## 8. Assets checklist

| Asset | Source | Notes |
| --- | --- | --- |
| Fig. 1: session tab + page | `./bench` screenshot of a running build | Light + dark; 2×; no private data |
| Fig. 2: split view | same | Session beside the page it builds |
| Fig. 3: tab strip / sidebar | same | Corner crop like Search's |
| App icon on plate | `Icon/icon.swift`, `Icon/mark.svg` | Reuse the Dock icon render |
| Favicon | `mark.svg` on a plate | SVG + 32/16 PNG |
| Apple touch icon | same, 180×180 | |
| OG image | Fig. 1 + one-liner | 1200×630, readable at small size |
| Fonts | Inter woff2, self-hosted | 400/500/600, subset if easy |

Screenshots should be made from the real app, with real-looking but harmless content
(no customer names, tokens, local paths, or email). Use `bench shot` so they are
reproducible, and keep a `site/scripts/shots.sh` note of the commands.

**Numbers policy:** every numeric claim needs a `measure` entry (what, how, when, on
which Mac). If a number is not measured, write prose instead. Do not borrow Search's
numbers — different app, different build, different daemon.

---

## 9. Milestones

| # | Deliverable | Est. |
| --- | --- | --- |
| M0 | `site/` scaffold: Astro, layout, tokens, `wrangler.jsonc`, one placeholder page; `npm run build` green | ½ day |
| M1 | Full page copy and section structure from §3, responsive, dark mode | 1 day |
| M2 | Screenshots and OG image; figures with captions; install/FAQ final | 1 day |
| M3 | Release aliases in `build.yml`; `site.yml` deploy workflow; custom domain live | ½ day |
| M4 | QA: links, mobile, keyboard/focus, Lighthouse, OG preview, `curl` headers; cross-link from `tabsh.cc` | ½ day |

M0–M2 can be reviewed on `npm run dev`; M3 is the first public URL.

Definition of done for v1:

- `https://browser.tabsh.cc` serves the page over HTTPS with no console errors and no
  third-party requests.
- Download buttons fetch the current arm64/Intel builds from GitHub Releases.
- The page is readable at 360px, works keyboard-only, and respects reduced motion.
- Copy contains no feature the fork does not actually ship.
- `tabsh.cc` links here; this page links back.

---

## 10. Risks and open questions

1. **Unverified claims.** Auto-update is off, passkeys are tied to upstream's Apple team,
   and default-browser registration is not done. The site must not promise them. Decide
   whether to mention "updates are manual for now" in the FAQ (recommended: yes, plainly).
2. **Ad-hoc signing.** Downloads need the right-click/quarantine note. Search's site can
   skip this because it is notarised; ours cannot. Put it in the install block, not only
   in the FAQ.
3. **Product naming.** "Tabs" on `browser.tabsh.cc` needs one sentence of context
   ("Tabs is tabsh's browser") so the domain and the name do not feel unrelated.
4. **Numbers.** Startup/memory claims need a bench run on this build; if that is not
   ready, ship without the numbers section rather than with borrowed figures.
5. **Download aliases.** `releases/latest` ignores drafts, so a hand-started draft will
   not be served — correct behaviour, but test with a real tag before launch.
6. **Cloudflare access.** Confirm the `tabsh.cc` zone can be used by this repo's Worker
   and that the API token has Workers Scripts:Edit for the account.
7. **Screenshot upkeep.** Session tabs and split view will change; keep the bench
   commands in `site/scripts/` so the figures can be regenerated in minutes.

---

## 11. Not in v1

- Changelog page (link to GitHub releases instead).
- Separate `/download` and `/download/intel` pages (direct aliases are enough).
- Live app demo (the page is static; screenshots carry the product).
- Docs (link to `tabsh.cc/docs/`).
- Analytics, A/B tests, newsletter, waitlist.
- Localisation.

These are additive later; nothing in the structure above blocks them.

---

## 12. Progress

- **M0 — done (2026-11-04).** `site/` scaffold: Astro, layout, tokens, placeholder page,
  404, favicon, touch icon, OG card, self-hosted Inter. `npm run check` and
  `npm run build` clean.
- **M1 — done.** Hero, session, split, browser features, install steps, FAQ and footer in
  place. Copy waits on real screenshots and measured numbers.
- **M2 — next.** Capture fig. 1–2 with a visible window. The offscreen probe can't paint
  SwiftTerm, and a visible test run hides itself on activation, so this needs either a
  manual window capture or a small screenshot mode in the app. Replace the OG card with
  the real screenshot afterwards.
- **M3 — done (2026-11-04).** Stable release aliases in `.github/workflows/build.yml`;
  `site.yml` added; `tabs-browser` deployed and `browser.tabsh.cc` is live over HTTPS.
  Remaining: set `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` on this repo so CI
  deploys too.
- **M4 — not started.** QA, headers, Lighthouse, cross-link from `tabsh.cc`.
