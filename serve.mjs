// norns-web dev server: serves the page and the script, reading files fresh on
// every request, and reloads the page by itself when a file changes.
//
//   node tools/norns-web/serve.mjs [script dir, default .] [port, default 8800]
//
// /files.json  the script's name, main file and every .lua file under its dir
// /script/...  the script's own files (for lib/Engine_<name>.js)
// /__reload    an event stream: "reload" whenever a watched file changes
// /proxy?url=  fetches an http(s) URL for the page and streams it back (redirects followed,
//              the final URL in x-norns-web-url), so CORS doesn't stop a script's curl or
//              a stand-in's audio streams while developing; the static build has no proxy
// /...         this directory (page, runtime, vendored wasmoon)
//
// Watched: the script's .lua, .js and .json files, and norns-web's own page and
// runtime; the page keeps its params across the reload (norns-web.js). Changes
// to this file or manifest.mjs need a restart (make web).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { manifest } from "./manifest.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const scriptDir = path.resolve(process.argv[2] || ".");
const port = +(process.argv[3] || 8800);
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".lua": "text/plain",
  ".json": "application/json", ".wasm": "application/wasm", ".css": "text/css", ".svg": "image/svg+xml",
  ".png": "image/png" };

function send(res, file) {
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    res.end(data);
  });
}

// resolve a URL path under a base dir, refusing anything that climbs out of it
function under(base, urlPath) {
  const file = path.resolve(base, "." + decodeURIComponent(urlPath));
  return file === base || file.startsWith(base + path.sep) ? file : null;
}

// ---------- live reload ----------
const clients = new Set();
const SKIP = /(^|[\\/])(\.git|node_modules|dist|pgm|\.scala-build|\.metals)([\\/]|$)/;
let pending = null, changed = new Set();
function onChange(base, name) {
  if (!name || SKIP.test(name) || !/\.(lua|js|json|html)$/.test(name)) return;
  changed.add(path.relative(scriptDir, path.join(base, name)) || name);
  clearTimeout(pending); // editors write in bursts: wait for the last one
  pending = setTimeout(() => {
    console.log(`changed: ${[...changed].join(", ")}; reloading ${clients.size} page(s)`);
    changed = new Set();
    for (const res of clients) res.write("data: reload\n\n");
  }, 150);
}
for (const dir of new Set([scriptDir, here])) {
  try { fs.watch(dir, { recursive: true }, (_, name) => onChange(dir, name)); }
  catch (e) { console.log(`can't watch ${dir} (${e.message}): reload the page by hand`); }
}

// the proxy: endless radio streams included, so the upstream fetch stops when the page lets go
async function proxy(req, res, target) {
  if (!/^https?:\/\//.test(target || "")) { res.writeHead(400); res.end("url= an http(s) URL"); return; }
  const ctl = new AbortController();
  req.on("close", () => ctl.abort());
  try {
    const headers = {};
    for (const h of ["user-agent", "range", "accept"]) if (req.headers[h]) headers[h] = req.headers[h];
    const up = await fetch(target, { method: req.method === "HEAD" ? "HEAD" : "GET", headers, redirect: "follow", signal: ctl.signal });
    const out = { "cache-control": "no-store", "x-norns-web-url": up.url };
    for (const h of ["content-type", "content-length", "accept-ranges", "content-range", "icy-name"]) {
      const v = up.headers.get(h);
      if (v) out[h] = v;
    }
    res.writeHead(up.status, out);
    if (!up.body || req.method === "HEAD") { res.end(); return; }
    for await (const chunk of up.body) if (!res.write(chunk)) await new Promise(r => res.once("drain", r));
    res.end();
  } catch (e) {
    if (ctl.signal.aborted) return;
    if (!res.headersSent) res.writeHead(502);
    res.end(String(e.message));
  }
}

http.createServer((req, res) => {
  const url = new URL(req.url, "http://x").pathname;
  if (url === "/files.json") {
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    res.end(JSON.stringify({ ...manifest(scriptDir, "script/"), dev: true }));
    return;
  }
  if (url === "/proxy") {
    proxy(req, res, new URL(req.url, "http://x").searchParams.get("url"));
    return;
  }
  if (url === "/__reload") {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive" });
    res.write(": watching\n\n");
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }
  const file = url.startsWith("/script/") ? under(scriptDir, url.slice("/script".length))
    : under(here, url === "/" ? "/index.html" : url);
  if (!file) { res.writeHead(403); res.end(); return; }
  send(res, file);
}).listen(port, "127.0.0.1", () => {
  console.log(`norns-web: ${path.basename(scriptDir)} at http://localhost:${port}/ (reloads when files change)`);
});
