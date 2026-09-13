import { cp, lstat, mkdir, readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { validateProduction } from './release-gate.mjs';

export const root = fileURLToPath(new URL('../', import.meta.url));
const sourceFiles = ['index.html', 'about/index.html', 'privacy/index.html', 'support/index.html', '404.html', 'styles.css', '_headers', 'robots.txt'];
const outputFiles = [...sourceFiles, 'assets/barline.png'];
const plausibleScript = 'https://plausible.io/js/pa-zm9NLR0vTVQctEpExKk2L.js';
const plausibleInitializer = 'window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};plausible.init()';

export function assertApprovedAnalytics(html, file = 'page') {
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)];
  const external = scripts.filter(match => /\ssrc=/.test(match[0]));
  const inline = scripts.filter(match => !/\ssrc=/.test(match[0]));
  if (scripts.length !== 2 || external.length !== 1 || inline.length !== 1 ||
      !external[0][0].includes(`async src="${plausibleScript}"`) ||
      inline[0][1].trim() !== plausibleInitializer) {
    throw new Error(`Static site permits only the approved Plausible loader and initializer: ${file}`);
  }
}

// Refuse stale checkout scripts, symlinks or unrelated assets before uploading.
// Never delete unknown output on the user's behalf.
export async function assertAllowedTree(directory, allowed, prefix = '') {
  let entries;
  try {
    if (!(await lstat(directory)).isDirectory()) throw new Error('Unexpected static-site root: a real directory is required.');
    entries = await readdir(directory, { withFileTypes: true });
  }
  catch (error) { if (error.code === 'ENOENT' && !prefix) return; throw error; }
  for (const entry of entries) {
    const path = prefix + entry.name;
    if (entry.isDirectory() && allowed.some(file => file.startsWith(path + '/'))) {
      await assertAllowedTree(join(directory, entry.name), allowed, path + '/');
    } else if (!entry.isFile() || !allowed.includes(path)) {
      throw new Error(`Unexpected static-site entry: ${path}. Review it before building.`);
    }
  }
}

// Static output, preview by default. No payment keys, account state, or bundler.
// Publishing is a separate operation after domain/account/release approval.
export async function build({ mode = 'preview', release, outputDirectory = join(root, 'dist') } = {}) {
  if (!['preview', 'production'].includes(mode)) throw new Error('Unknown site build mode.');
  if (mode === 'preview' && release !== undefined) throw new Error('Release configuration requires explicit production mode.');
  const output = outputDirectory;
  await assertAllowedTree(join(root, 'src'), sourceFiles);
  await assertAllowedTree(output, outputFiles);
  const pages = new Map();
  for (const file of sourceFiles.filter(file => file.endsWith('.html'))) {
    const html = await readFile(join(root, 'src', file), 'utf8');
    if (/<iframe\b|<form\b|on(?:click|load|error)=/i.test(html)) throw new Error('Static site must not embed checkout, forms, or event handlers.');
    assertApprovedAnalytics(html, file);
    pages.set(file, html);
  }
  if (mode === 'production') {
    validateProduction({ release, pages,
      headers: await readFile(join(root, 'src', '_headers'), 'utf8'),
      robots: await readFile(join(root, 'src', 'robots.txt'), 'utf8') });
  }
  await mkdir(output, { recursive: true });
  const files = await readdir(join(root, 'src'));
  for (const file of files) {
    await cp(join(root, 'src', file), join(output, file), { recursive: true });
  }
  await mkdir(join(output, 'assets'), { recursive: true });
  await cp(join(root, '../Barline/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png'), join(output, 'assets/barline.png'));
  console.log(`Barline ${mode} site built. No deployment, release approval, or payment activation performed.`);
  return output;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 0) await build();
  else if (args.length === 2 && args[0] === '--production') {
    const raw = await readFile(args[1], 'utf8');
    if (Buffer.byteLength(raw) > 8192) throw new Error('Release configuration exceeds its size bound.');
    await build({ mode: 'production', release: JSON.parse(raw) });
  } else {
    throw new Error('Usage: node scripts/build.mjs [--production /absolute/approved-release.json]');
  }
}
