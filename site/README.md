# browser.tabsh.cc

The one-page marketing site for **Tabs**, the macOS browser with tabsh inside it.
Astro, static output, no client framework. The plan lives in [`../SITE.md`](../SITE.md).

## Run it

```sh
cd site
npm install
npm run dev        # http://localhost:4321
```

## Check and build

```sh
npm run check      # astro check (types, templates)
npm run build      # static output in dist/
npm run preview    # serve dist/
```

## Deploy

The Worker is `tabs-browser`, serving `dist/` as static assets on
`browser.tabsh.cc` (see `wrangler.jsonc`). `src/worker.ts` is the only code: it
redirects `http://` to `https://` and then hands the request to the assets. The
`tabsh.cc` zone is in the same Cloudflare account.

```sh
npx wrangler deploy
```

CI does the same on pushes that touch `site/`, guarded by
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.

## Editing

- Copy and section order: `SITE.md` §3 and `src/pages/index.astro`.
- Version, size and download URLs: `src/site.ts`. Download links point at stable
  release aliases (`Tabs.dmg`, `Tabs-intel.dmg`), added by the build workflow.
- Colours, type and layout: `src/styles/site.css`. Tokens are at the top.
- Social image: `public/og.png` (1200 × 630). Replace it when the real
  screenshot exists.

Do not add analytics, third-party fonts, or a client framework. The page should
make no requests other than its own files.
