#!/usr/bin/env node
// Tiny session editor for spirit-agent.
//
// A zero-dependency Node server (only the built-in http/fs/path modules) that
// serves a browser UI for viewing and editing the agent's session.jsonl — the
// single source of truth that agent.sh replays verbatim to the model. No build
// step, no npm install, no node_modules; mirrors agent.sh's "one self-contained
// thing you just run" design.
//
// Usage:
//   node ui/server.js                       # serve ./session.jsonl (repo root), open browser
//   node ui/server.js --port 9000
//   node ui/server.js --session /path/to/other/session.jsonl
//   SESSION_FILE=... node ui/server.js --no-open
//
// Safety:
//   * Every save first copies the current file to session.jsonl.bak.<UTC stamp>,
//     the same convention compact_session() uses.
//   * Writes are atomic (temp file + rename).
//   * If a live agent run holds session.jsonl.lock, saving is refused (HTTP 409)
//     unless the request sets {"force": true} — editing while a turn is in
//     flight would interleave with the run.

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const HERE = __dirname;
const INDEX_HTML = path.join(HERE, 'index.html');

// Defaults match agent.sh's discovery, applied to this folder's parent (the
// agent folder when ui/ is dropped inside one): an explicit SESSION_FILE wins;
// else a legacy session.jsonl; else the folder's single session-*.jsonl; else
// fall back to the legacy path (shown as missing).
function discoverSession(dir) {
  const legacy = path.join(dir, 'session.jsonl');
  if (fs.existsSync(legacy)) return legacy;
  let matches = [];
  try {
    matches = fs
      .readdirSync(dir)
      .filter((f) => f.startsWith('session-') && f.endsWith('.jsonl'))
      .sort();
  } catch {
    /* unreadable dir: fall through to legacy */
  }
  if (matches.length === 1) return path.join(dir, matches[0]);
  if (matches.length > 1) {
    console.error(`several session files in ${dir}; pass --session to pick one`);
  }
  return legacy;
}
const DEFAULT_SESSION =
  process.env.SESSION_FILE || discoverSession(path.dirname(HERE));

// ISO-8601 UTC stamp, matching agent.sh's utc_now() (whole seconds, trailing Z).
function utcNow() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Timestamp for backup filenames, matching compact_session()'s format.
function backupStamp() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

// Report whether a live agent run holds the session lock. agent.sh's
// acquire_session_lock() makes a `<session>.lock` directory with the owner pid
// in `<lock>/pid`; a lock whose pid is dead is a crash leftover.
function lockStatus(sessionFile) {
  const lockDir = sessionFile + '.lock';
  if (!fs.existsSync(lockDir) || !fs.statSync(lockDir).isDirectory()) {
    return { locked: false, owner: null };
  }
  let owner = null;
  try {
    owner = fs.readFileSync(path.join(lockDir, 'pid'), 'utf8').trim();
  } catch {
    owner = null;
  }
  let alive = false;
  if (owner && /^\d+$/.test(owner)) {
    try {
      process.kill(Number(owner), 0); // signal 0 = existence check
      alive = true;
    } catch (err) {
      alive = err.code === 'EPERM'; // exists, just not ours to signal
    }
  }
  return { locked: alive, owner };
}

// Parse session.jsonl into a list of message records plus any parse errors.
// Each record is returned verbatim with an added _index so the client can keep
// ordering stable; unparseable lines are reported, not silently dropped.
function readSession(sessionFile) {
  const messages = [];
  const errors = [];
  const exists = fs.existsSync(sessionFile) && fs.statSync(sessionFile).isFile();
  if (exists) {
    const text = fs.readFileSync(sessionFile, 'utf8');
    const lines = text.split('\n');
    lines.forEach((line, i) => {
      if (!line.trim()) return;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch (err) {
        errors.push({ line: i + 1, error: String(err.message), raw: line });
        return;
      }
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
        obj._index = messages.length;
        messages.push(obj);
      } else {
        errors.push({ line: i + 1, error: 'line is not a JSON object', raw: line });
      }
    });
  }
  const info = lockStatus(sessionFile);
  return {
    session_file: path.resolve(sessionFile),
    exists,
    messages,
    errors,
    locked: info.locked,
    lock_owner: info.owner,
  };
}

// Canonical key order for tidy, agent.sh-like lines. Any extra keys a record
// carries (ephemeral, usage, tool_calls, tool_call_id, ...) are kept after.
const KEY_ORDER = ['kind', 'created_at', 'role', 'content'];

// Return a copy with kind/created_at defaulted and keys in a stable order. The
// client owns the friendly fields; this just guarantees a well-formed line and
// never drops unknown keys.
function normalizeRecord(rec) {
  const out = {};
  const src = Object.assign({}, rec);
  delete src._index;
  delete src._uid;
  if (src.kind === undefined) src.kind = 'message';
  if (!src.created_at) src.created_at = utcNow();
  for (const k of KEY_ORDER) if (k in src) out[k] = src[k];
  for (const k of Object.keys(src)) if (!(k in out)) out[k] = src[k];
  return out;
}

// Back up the current file, then atomically write the new message list: one
// compact JSON object per line, UTF-8 (matching jq -c output). Returns the
// backup path (or null if there was nothing to back up).
function writeSession(sessionFile, messages) {
  let backup = null;
  if (fs.existsSync(sessionFile) && fs.statSync(sessionFile).isFile()) {
    backup = `${sessionFile}.bak.${backupStamp()}`;
    fs.copyFileSync(sessionFile, backup);
  }
  const body = messages.map((m) => JSON.stringify(normalizeRecord(m))).join('\n');
  const tmp = `${sessionFile}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, messages.length ? body + '\n' : '', 'utf8');
  fs.renameSync(tmp, sessionFile);
  return { ok: true, backup, count: messages.length };
}

function sendJSON(res, code, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function sendHTML(res) {
  let body;
  try {
    body = fs.readFileSync(INDEX_HTML);
  } catch {
    return sendJSON(res, 500, { error: `cannot read ${INDEX_HTML}` });
  }
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 64 * 1024 * 1024) reject(new Error('request body too large'));
      else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function makeServer(sessionFile) {
  return http.createServer(async (req, res) => {
    const url = req.url || '/';
    if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
      return sendHTML(res);
    }
    if (req.method === 'GET' && url.startsWith('/api/session')) {
      try {
        return sendJSON(res, 200, readSession(sessionFile));
      } catch (err) {
        return sendJSON(res, 500, { error: String(err.message) });
      }
    }
    if (req.method === 'POST' && url.startsWith('/api/session')) {
      let payload;
      try {
        const raw = await readBody(req);
        payload = raw ? JSON.parse(raw) : {};
      } catch (err) {
        return sendJSON(res, 400, { error: `invalid JSON body: ${err.message}` });
      }
      const messages = payload.messages;
      if (
        !Array.isArray(messages) ||
        !messages.every((m) => m && typeof m === 'object' && !Array.isArray(m))
      ) {
        return sendJSON(res, 400, { error: 'messages must be a list of objects' });
      }
      const info = lockStatus(sessionFile);
      if (info.locked && !payload.force) {
        return sendJSON(res, 409, {
          error: 'session is locked by a live agent run',
          lock_owner: info.owner,
        });
      }
      try {
        return sendJSON(res, 200, writeSession(sessionFile, messages));
      } catch (err) {
        return sendJSON(res, 500, { error: String(err.message) });
      }
    }
    sendJSON(res, 404, { error: 'not found' });
  });
}

function parseArgs(argv) {
  const opts = {
    host: '127.0.0.1',
    port: 8765,
    session: DEFAULT_SESSION,
    open: true,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--host') opts.host = argv[++i];
    else if (a === '--port') opts.port = Number(argv[++i]);
    else if (a === '--session') opts.session = argv[++i];
    else if (a === '--no-open') opts.open = false;
    else if (a === '-h' || a === '--help') {
      console.log(
        'usage: node ui/server.js [--host H] [--port P] [--session FILE] [--no-open]'
      );
      process.exit(0);
    }
  }
  return opts;
}

function openBrowser(url) {
  const cmd =
    process.platform === 'darwin'
      ? 'open'
      : process.platform === 'win32'
        ? 'cmd'
        : 'xdg-open';
  const args = process.platform === 'win32' ? ['/c', 'start', '', url] : [url];
  execFile(cmd, args, () => {}); // best-effort; ignore failure
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const sessionFile = path.resolve(opts.session);
  const server = makeServer(sessionFile);
  // If the requested port is taken (e.g. several agent UIs side by side),
  // walk up one port at a time until a free one is found.
  let port = opts.port;
  let triesLeft = 100;
  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && triesLeft > 0) {
      triesLeft -= 1;
      console.log(`port ${port} is busy; trying ${port + 1}`);
      port += 1;
      server.listen(port, opts.host);
      return;
    }
    console.error(`server error: ${err.message}`);
    process.exit(1);
  });
  server.on('listening', () => {
    const url = `http://${opts.host}:${port}/`;
    console.log(`session editor: ${url}`);
    console.log(`editing: ${sessionFile}`);
    console.log('press Ctrl-C to stop');
    if (opts.open) openBrowser(url);
  });
  server.listen(port, opts.host);
}

main();
