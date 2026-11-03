import { defineConfig } from 'astro/config';

// One static page, no client framework. Cloudflare serves ./dist as Worker
// static assets; see wrangler.jsonc.
export default defineConfig({
  site: 'https://browser.tabsh.cc',
  output: 'static',
  devToolbar: { enabled: false },
  build: { inlineStylesheets: 'auto' },
});
