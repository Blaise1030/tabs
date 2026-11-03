// Everything the page needs to know about where it lives and what it offers.
// Keep the version in step with the repo's VERSION file; the release workflow
// can rewrite these two lines later instead of a person doing it.

export const SITE_URL = 'https://browser.tabsh.cc';
export const REPO_URL = 'https://github.com/Blaise1030/tabs';
export const TABSH_URL = 'https://tabsh.cc';

export const VERSION = '1.1.0';
/** Set when a DMG has actually been measured; leave null until then. */
export const SIZE_MB: number | null = 11.9;

// Stable aliases added to every GitHub release by .github/workflows/build.yml,
// so these links never change from one version to the next.
export const DOWNLOAD_ARM64 = `${REPO_URL}/releases/latest/download/Tabs.dmg`;
export const DOWNLOAD_INTEL = `${REPO_URL}/releases/latest/download/Tabs-intel.dmg`;
export const RELEASES_URL = `${REPO_URL}/releases/latest`;
