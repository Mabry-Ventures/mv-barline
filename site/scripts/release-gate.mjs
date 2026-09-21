const canonical = 'https://usebarline.com';
const repository = 'https://github.com/Mabry-Ventures/mv-barline';
const checkout = 'https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02';

// Operator configuration is not a release certificate. This gate prevents an
// accidental staging upload or mismatched destination; published artifact and
// application qualification must be verified separately before deployment.
export function validateProduction({ release, pages, headers, robots }) {
  if (!release || typeof release !== 'object' || Array.isArray(release)) {
    throw new Error('Production requires an explicitly supplied release configuration.');
  }
  const { version } = release;
  if (typeof version !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
    throw new Error('Production requires a stable, explicit release version.');
  }
  const prefix = `${repository}/releases/download/v${version}`;
  const expected = {
    canonicalOrigin: canonical,
    downloadURL: `${prefix}/Barline-${version}.dmg`,
    sourceURL: `${prefix}/Barline-${version}-source.tar.gz`,
    checksumsURL: `${prefix}/SHA256SUMS`,
    releaseURL: `${repository}/releases/tag/v${version}`,
    contributionURL: checkout,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (release[key] !== value) throw new Error(`Missing or unexpected production destination: ${key}`);
  }
  if (Object.keys(release).some(key => !['version', ...Object.keys(expected)].includes(key))) {
    throw new Error('Unexpected release configuration field. Keep credentials and provider state out of site builds.');
  }
  const approvedExternal = new Set([
    'mailto:support@mabryventures.com',
    ...Object.values(expected), canonical + '/', canonical + '/about/', canonical + '/privacy/', canonical + '/support/',
    repository, repository + '/issues', repository + '/issues/new/choose',
    ...['LICENSE', 'NOTICE.md', 'THIRD_PARTY_NOTICES.md', 'SECURITY.md', 'FREQUENT_ISSUES.md', 'docs/PROVENANCE.md']
      .map(path => `${repository}/blob/main/${path}`),
    'https://github.com/jordanbaird/Ice', 'https://github.com/lxy1992/Ice',
    'https://stripe.com/privacy', 'https://www.cloudflare.com/privacypolicy/', 'https://plausible.io/data-policy',
  ]);
  for (const file of ['index.html', 'about/index.html', 'privacy/index.html', 'support/index.html', '404.html']) {
    if (!pages.has(file)) throw new Error(`Missing production page: ${file}`);
  }
  // Constrain authored markup rather than claim a general HTML/visibility audit.
  // Browser accessibility, CSS visibility and launch QA remain separate gates.
  for (const [file, html] of pages) {
    if (/<!--|<template\b/i.test(html)) {
      throw new Error(`Production link validation requires comment-free markup without templates: ${file}`);
    }
    const hrefAttributes = [...html.matchAll(/\shref\s*=/gi)].length;
    const quotedHrefs = [...html.matchAll(/\shref\s*=\s*(?:"[^"]*"|'[^']*')/gi)].length;
    if (hrefAttributes !== quotedHrefs) throw new Error(`Production requires quoted href attributes: ${file}`);
    for (const [, href] of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi)) {
      if (/[\\\u0000-\u0020\u007f]|&/.test(href)) throw new Error(`Production requires literal, unambiguous destinations: ${file}`);
      if ((href.startsWith('/') && !href.startsWith('//')) || href.startsWith('#')) continue;
      if (!approvedExternal.has(href)) throw new Error(`Production contains an unqualified alternate destination: ${file}`);
    }
  }
  const home = pages.get('index.html');
  if (!home) throw new Error('Production homepage is missing.');
  for (const key of ['downloadURL', 'sourceURL', 'checksumsURL', 'releaseURL', 'contributionURL']) {
    const anchors = [...home.matchAll(/<a\s[^>]*>/gi)].map(match => match[0]);
    if (!anchors.some(anchor => [...anchor.matchAll(/\shref\s*=\s*"([^"]+)"/gi)]
      .some(([, href]) => href === expected[key]))) throw new Error(`Production homepage must link ${key}.`);
  }
  for (const [file, html] of pages) {
    if (file === '404.html') continue;
    const path = file === 'index.html' ? '/' : `/${file.replace(/index\.html$/, '')}`;
    if (!html.includes(`<link rel="canonical" href="${canonical}${path}">`)) {
      throw new Error(`Production canonical URL is missing or incorrect: ${file}`);
    }
    if (/noindex|nofollow|preview site|Downloads will appear here after final qualification|first public release is being prepared/i.test(html)) {
      throw new Error(`Production still contains preview-only availability or indexing: ${file}`);
    }
  }
  if (/X-Robots-Tag:\s*[^\n]*(?:noindex|nofollow)/i.test(headers) ||
      /^\s*Disallow:\s*\/\s*$/mi.test(robots)) {
    throw new Error('Production indexing is still disabled.');
  }
}
