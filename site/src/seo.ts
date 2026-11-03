import { SITE_URL } from './site.ts';

/** Social preview, made in M2. Kept here so every page shares one image. */
export const OG_IMAGE = {
  path: '/og.png',
  width: 1200,
  height: 630,
  alt: 'Tabs, a Mac browser with a tabsh session in the tab strip',
} as const;

function canonicalPath(pathname: string): string {
  if (pathname === '' || pathname === '/') return '/';
  return pathname.endsWith('/') ? pathname : `${pathname}/`;
}

/** Absolute tags for a marketing page. Crawlers ignore relative og:image URLs. */
export function pageSeo(input: { title: string; description: string; pathname: string }) {
  const canonical = new URL(canonicalPath(input.pathname), SITE_URL).href;
  const image = new URL(OG_IMAGE.path, SITE_URL).href;
  const home = new URL(canonical).pathname === '/';

  const website: Record<string, unknown> = {
    '@type': 'WebSite',
    '@id': `${SITE_URL}/#website`,
    name: 'Tabs',
    url: `${SITE_URL}/`,
  };
  if (home) website.description = input.description;

  const graph: Record<string, unknown>[] = [
    website,
    {
      '@type': 'WebPage',
      '@id': `${canonical}#webpage`,
      url: canonical,
      name: input.title,
      description: input.description,
      isPartOf: { '@id': website['@id'] },
      primaryImageOfPage: image,
    },
  ];

  if (home) {
    graph.push({
      '@type': 'SoftwareApplication',
      name: 'Tabs',
      applicationCategory: 'BrowserApplication',
      operatingSystem: 'macOS 14 or later',
      url: canonical,
      image,
      description: input.description,
      offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    });
  }

  return {
    canonical,
    image,
    imageAlt: OG_IMAGE.alt,
    imageWidth: OG_IMAGE.width,
    imageHeight: OG_IMAGE.height,
    // `<` would close the script tag if a title ever contained it.
    jsonLd: JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }).replace(/</g, '\\u003c'),
  };
}
