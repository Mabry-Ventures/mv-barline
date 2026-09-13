import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat, mkdtemp, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build, assertAllowedTree } from '../scripts/build.mjs';

const output = await build();
const pages = ['index.html', 'about/index.html', 'privacy/index.html', 'support/index.html', '404.html'];
test('build refuses unexpected stale files and symlinks without deleting them', async () => {
  const fixture = await mkdtemp(join(tmpdir(), 'barline-site-manifest-'));
  try {
    await writeFile(join(fixture, 'old-checkout.js'), 'stale');
    await assert.rejects(assertAllowedTree(fixture, ['index.html']), /Unexpected/);
    assert.equal(await readFile(join(fixture, 'old-checkout.js'), 'utf8'), 'stale');
    await symlink('old-checkout.js', join(fixture, 'index.html'));
    await assert.rejects(assertAllowedTree(fixture, ['index.html', 'old-checkout.js']), /Unexpected/);
    await symlink(fixture, join(fixture, 'linked-root'));
    await assert.rejects(assertAllowedTree(join(fixture, 'linked-root'), ['index.html', 'old-checkout.js', 'linked-root']), /real directory/);
  } finally { await rm(fixture, { recursive: true }); }
});
test('production pages have semantic headings, canonical URLs and no tracking/payment code', async () => {
  for (const path of pages) {
    const html = await readFile(join(output, path), 'utf8');
    assert.match(html, /<html lang="en">/);
    assert.match(html, /name="viewport"/);
    assert.equal((html.match(/<h1\b/g) ?? []).length, 1);
    assert.doesNotMatch(html, /<script\b|<iframe\b|<form\b|on(?:click|load|error)=/i);
    if (path === '404.html') {
      assert.match(html, /name="robots" content="noindex/);
    } else {
      assert.doesNotMatch(html, /name="robots" content="(?:noindex|nofollow)/);
      const suffix = path === 'index.html' ? '/' : `/${path.replace(/index\.html$/, '')}`;
      assert.match(html, new RegExp(`<link rel="canonical" href="https://usebarline\\.com${suffix}">`));
    }
  }
});
test('every local link and asset resolves, every local fragment exists', async () => {
  for (const path of pages) {
    const html = await readFile(join(output, path), 'utf8');
    for (const [, raw] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      const url = new URL(raw, `https://barline.invalid/${path}`);
      if (url.origin !== 'https://barline.invalid') {
        assert.equal(url.protocol, 'https:');
        continue;
      }
      const target = join(output, url.pathname, url.pathname.endsWith('/') ? 'index.html' : '');
      assert.ok((await stat(target)).isFile(), raw);
      if (url.hash) assert.ok((await readFile(target, 'utf8')).includes(`id="${url.hash.slice(1)}"`), raw);
    }
  }
});
test('production links the qualified release and presents the supported configuration', async () => {
  const html = await readFile(join(output, 'index.html'), 'utf8');
  assert.match(html, /Download Barline 1\.0\.12/);
  assert.match(html, /Barline 1\.0\.12 release notes/);
  assert.match(html, /Corresponding source/);
  assert.match(html, /Checksums/);
  assert.match(html, /Apple Silicon · macOS 26/);
  assert.doesNotMatch(html, /macOS 27 compatibility has not yet been qualified\./);
  for (const capability of ['visible, hidden, and always-hidden', 'three-dot control', 'Search your menu bar locally', 'Save useful layouts', 'native macOS Focus Filter', 'display-specific layouts']) {
    assert.ok(html.includes(capability), capability);
  }
  assert.doesNotMatch(html, /preview site|final qualification|noindex|nofollow/i);
});
test('contributions use only the approved live hosted link with accurate privacy copy', async () => {
  const html = await readFile(join(output, 'index.html'), 'utf8');
  const support = await readFile(join(output, 'support/index.html'), 'utf8');
  const privacy = await readFile(join(output, 'privacy/index.html'), 'utf8');
  const checkoutLinks = [...html.matchAll(/href="(https:\/\/(?:buy|checkout)\.stripe\.com\/[^\"]+)"/g)].map(match => match[1]);
  assert.deepEqual(checkoutLinks, ['https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02']);
  assert.match(support, /href="https:\/\/buy\.stripe\.com\/cNibJ1a370l33AVgnk1ck02" rel="noreferrer">Contribute via Stripe/);
  assert.match(html, /rel="noreferrer">Contribute via Stripe/);
  assert.match(html, /One-time support for Mabry Ventures LLC/);
  assert.match(privacy, /can access transaction details through Stripe/);
  assert.match(privacy, /do not collect full card numbers or security codes/);
  assert.match(privacy, /https:\/\/stripe.com\/privacy/);
  for (const path of pages) {
    const page = await readFile(join(output, path), 'utf8');
    assert.doesNotMatch(page, /buy\.stripe\.com\/test_|sk_(?:live|test)_|pk_(?:live|test)_/);
  }
});
test('support navigation has a real destination with help and contribution actions', async () => {
  const home = await readFile(join(output, 'index.html'), 'utf8');
  const support = await readFile(join(output, 'support/index.html'), 'utf8');
  assert.equal((home.match(/href="\/support\/"/g) ?? []).length, 2);
  assert.doesNotMatch(home, /href="#support">Support/);
  assert.match(support, /href="https:\/\/github\.com\/Mabry-Ventures\/mv-barline\/issues\/new\/choose">Report an issue/);
  assert.match(support, /href="https:\/\/github\.com\/Mabry-Ventures\/mv-barline\/blob\/main\/FREQUENT_ISSUES\.md">troubleshooting guide/);
});
test('static security policy disallows executable/embed/payment surfaces', async () => {
  const headers = await readFile(join(output, '_headers'), 'utf8');
  const robots = await readFile(join(output, 'robots.txt'), 'utf8');
  for (const value of ["default-src 'none'", "frame-ancestors 'none'", "form-action 'none'", 'no-referrer', 'nosniff']) assert.ok(headers.includes(value));
  assert.doesNotMatch(headers, /noindex|nofollow/i);
  assert.match(robots, /^Allow: \/$/m);
});
test('About preserves provenance while the footer stays focused on navigation', async () => {
  const home = await readFile(join(output, 'index.html'), 'utf8');
  const about = await readFile(join(output, 'about/index.html'), 'utf8');
  assert.match(home, /href="\/about\/"/);
  assert.doesNotMatch(home.match(/<footer[\s\S]*<\/footer>/)[0], /Ice|Derived from/);
  for (const credit of ['Jordan Baird', 'Xinyan Lu', 'Ice', 'GNU General Public License', 'THIRD_PARTY_NOTICES.md', 'PROVENANCE.md']) assert.ok(about.includes(credit));
});
test('site remains lightweight without a client-side framework', async () => {
  const files = [...pages, 'styles.css', 'assets/barline.png'];
  let bytes = 0;
  for (const path of files) bytes += (await stat(join(output, path))).size;
  assert.ok(bytes < 100_000, `Static payload budget exceeded: ${bytes}`);
});
