import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateProduction } from '../scripts/release-gate.mjs';
import { build } from '../scripts/build.mjs';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function fixture() {
  // Synthetic destinations only: this does not assert a published release.
  const version = '9.8.7';
  const release = {
    version, canonicalOrigin: 'https://usebarline.com',
    downloadURL: `https://github.com/Mabry-Ventures/mv-barline/releases/download/v${version}/Barline-${version}.dmg`,
    sourceURL: `https://github.com/Mabry-Ventures/mv-barline/releases/download/v${version}/Barline-${version}-source.tar.gz`,
    checksumsURL: `https://github.com/Mabry-Ventures/mv-barline/releases/download/v${version}/SHA256SUMS`,
    releaseURL: `https://github.com/Mabry-Ventures/mv-barline/releases/tag/v${version}`,
    contributionURL: 'https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02',
  };
  return { release, headers: "/*\n  Content-Security-Policy: default-src 'none'\n", robots: 'User-agent: *\nAllow: /\n',
    pages: new Map([['index.html', `<link rel="canonical" href="https://usebarline.com/">${Object.entries(release).filter(([key]) => key.endsWith('URL')).map(([, url]) => `<a href="${url}">Link</a>`).join('')}`],
      ['about/index.html', '<link rel="canonical" href="https://usebarline.com/about/">'],
      ['privacy/index.html', '<link rel="canonical" href="https://usebarline.com/privacy/">'],
      ['support/index.html', '<link rel="canonical" href="https://usebarline.com/support/">'],
      ['404.html', '<meta name="robots" content="noindex">']]) };
}

test('production requires explicit versioned destinations, never an implicit latest release', () => {
  assert.doesNotThrow(() => validateProduction(fixture()));
  for (const key of Object.keys(fixture().release)) {
    const value = fixture(); delete value.release[key];
    assert.throws(() => validateProduction(value));
  }
  for (const version of ['1.2.3-rc1', 'latest', '01.2.3', '<script>', '', 123]) {
    const value = fixture(); value.release.version = version;
    assert.throws(() => validateProduction(value));
  }
  for (const url of ['http://github.com/Mabry-Ventures/mv-barline/a.zip', 'https://github.com.evil.invalid/a.zip',
    'https://github.com/Mabry-Ventures/mv-barline/releases/latest', fixture().release.downloadURL + '?token=secret']) {
    const value = fixture(); value.release.downloadURL = url;
    assert.throws(() => validateProduction(value));
  }
  const unexpected = fixture(); unexpected.release.apiKey = 'never-needed';
  assert.throws(() => validateProduction(unexpected), /Unexpected release configuration field/);
});

test('production rejects missing links, canonical mistakes, preview copy and indexing blocks', () => {
  for (const [file, suffix] of [['index.html', 'preview site'], ['about/index.html', 'noindex'], ['privacy/index.html', 'nofollow']]) {
    const value = fixture(); value.pages.set(file, value.pages.get(file) + suffix);
    assert.throws(() => validateProduction(value));
  }
  const missing = fixture(); missing.pages.set('index.html', '');
  assert.throws(() => validateProduction(missing));
  const wrongCanonical = fixture(); wrongCanonical.pages.set('about/index.html', '<link rel="canonical" href="https://staging.barline-site.pages.dev/about/">');
  assert.throws(() => validateProduction(wrongCanonical));
  for (const target of ['https://staging.barline-site.pages.dev/', 'https://buy.stripe.com/test_fake', 'https://github.com/jordanbaird/Ice/releases/latest',
    'https://github.com/Other/Thing/releases/download/v1/app.zip', 'https://buy.stripe.com/another-live-link', '//wrong.invalid/download.zip']) {
    const value = fixture(); value.pages.set('index.html', value.pages.get('index.html') + `<a href="${target}">Alternate</a>`);
    assert.throws(() => validateProduction(value));
  }
  const header = fixture(); header.headers += '  X-Robots-Tag: noindex, nofollow\n';
  assert.throws(() => validateProduction(header));
  const robots = fixture(); robots.robots = 'User-agent: *\nDisallow: /\n';
  assert.throws(() => validateProduction(robots));
});

test('production rejects comment, template and non-anchor substitutes', () => {
  for (const wrap of [html => `<!--${html}-->`, html => `<template>${html}</template>`,
    html => html.replaceAll('<a ', '<span ').replaceAll('</a>', '</span>')]) {
    const value = fixture(); value.pages.set('index.html', wrap(value.pages.get('index.html')));
    assert.throws(() => validateProduction(value));
  }
  const missingPage = fixture(); missingPage.pages.delete('about/index.html');
  assert.throws(() => validateProduction(missingPage), /Missing production page/);
  const unquoted = fixture(); unquoted.pages.set('index.html', unquoted.pages.get('index.html') + '<a href=https://wrong.invalid>Download</a>');
  assert.throws(() => validateProduction(unquoted), /quoted href/);
  const dataOnly = fixture(); dataOnly.pages.set('index.html', dataOnly.pages.get('index.html').replaceAll('<a href=', '<a data-href='));
  assert.throws(() => validateProduction(dataOnly), /homepage must link/);
  for (const href of ['/\\wrong.invalid/download', '/&#92;wrong.invalid/download', '/\t/wrong.invalid']) {
    const ambiguous = fixture(); ambiguous.pages.set('index.html', ambiguous.pages.get('index.html') + `<a href="${href}">Download</a>`);
    assert.throws(() => validateProduction(ambiguous), /unambiguous destinations/);
  }
});

test('current production source requires exact configuration and preserves source', async () => {
  const source = new URL('../src/index.html', import.meta.url);
  const before = await readFile(source, 'utf8');
  const outputDirectory = await mkdtemp(join(tmpdir(), 'barline-production-gate-'));
  const release = {
    version: '1.0.48',
    canonicalOrigin: 'https://usebarline.com',
    downloadURL: 'https://github.com/Mabry-Ventures/mv-barline/releases/download/v1.0.48/Barline-1.0.48.dmg',
    sourceURL: 'https://github.com/Mabry-Ventures/mv-barline/releases/download/v1.0.48/Barline-1.0.48-source.tar.gz',
    checksumsURL: 'https://github.com/Mabry-Ventures/mv-barline/releases/download/v1.0.48/SHA256SUMS',
    releaseURL: 'https://github.com/Mabry-Ventures/mv-barline/releases/tag/v1.0.48',
    contributionURL: 'https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02',
  };
  try {
    await writeFile(join(outputDirectory, 'index.html'), 'Preserve existing output');
    await assert.rejects(build({ mode: 'production', outputDirectory }), /release configuration/);
    await assert.doesNotReject(build({ mode: 'production', release, outputDirectory }));
    await assert.rejects(build({ mode: 'typo', outputDirectory }), /Unknown/);
    await assert.rejects(build({ mode: 'preview', release, outputDirectory }), /explicit production/);
    assert.equal(await readFile(source, 'utf8'), before);
    assert.match(await readFile(join(outputDirectory, 'index.html'), 'utf8'), /Download Barline 1\.0\.48/);
  } finally { await rm(outputDirectory, { recursive: true }); }
});
