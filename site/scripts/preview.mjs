import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';
import { build } from './build.mjs';

const output = await build();
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.txt': 'text/plain; charset=utf-8' };
const policy = "default-src 'none'; script-src https://plausible.io 'sha256-Ebt84R/xi8miDnxS/0/bkTjVgDRKQpWS1eI09TLbNkg='; connect-src https://plausible.io; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'";
const server = createServer(async (request, response) => {
  response.setHeader('Content-Security-Policy', policy);
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('Cache-Control', 'no-store');
  if (request.method !== 'GET' && request.method !== 'HEAD') { response.writeHead(405); response.end(); return; }
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    let file = resolve(output, `.${pathname}`);
    if (!file.startsWith(output + sep) && file !== output) throw new Error('Outside site');
    if ((await stat(file)).isDirectory()) file = resolve(file, 'index.html');
    const content = await readFile(file);
    response.setHeader('Content-Type', types[extname(file)] ?? 'application/octet-stream');
    response.writeHead(200); response.end(request.method === 'HEAD' ? undefined : content);
  } catch {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.writeHead(404);
    response.end(request.method === 'HEAD' ? undefined : await readFile(resolve(output, '404.html')));
  }
});
server.listen(4178, '127.0.0.1', () => console.log('Local preview: http://127.0.0.1:4178 (loopback only)'));
