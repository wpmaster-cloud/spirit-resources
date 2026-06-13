// core: DOM helpers, API client, live fleet state, router, layer
// primitives. The other files (fleet.js, agent.js, sheets.js) define
// the screens; load order doesn't matter — routing starts on
// DOMContentLoaded. DOM is built with h() + textContent everywhere:
// session content is arbitrary text and must never be parsed as HTML.
'use strict';

// ---- DOM -------------------------------------------------------------

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(kid));
  }
  return el;
}

// replaceChildren that flattens arrays and drops null/false — the same
// normalization h() applies to its kids.
function setKids(el, ...kids) {
  el.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false));
}

// ---- icons -----------------------------------------------------------
// Lucide-style line icons drawn in currentColor, sized to 1em so they
// scale with the button's font. The glyph strings are STATIC LITERALS
// (never session content), so innerHTML is safe here — the "never parse
// session text as HTML" rule still holds everywhere else.
const _ico = (inner) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ` +
  `stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
const _fill = (inner) => `<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">${inner}</svg>`;

const ICONS = {
  run:    _fill('<path d="M7 5.2v13.6a1 1 0 0 0 1.5.86l11.3-6.8a1 1 0 0 0 0-1.72L8.5 4.34A1 1 0 0 0 7 5.2z"/>'),
  stop:   _fill('<rect x="6" y="6" width="12" height="12" rx="2.5"/>'),
  log:    _ico('<polyline points="5 17 10 12 5 7"/><line x1="13" y1="18" x2="20" y2="18"/>'),
  plus:   _ico('<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>'),
  spark:  _fill('<path d="M12 2.5l1.9 6.1a2 2 0 0 0 1.3 1.3L21.5 12l-6.3 2.1a2 2 0 0 0-1.3 1.3L12 21.5l-1.9-6.1a2 2 0 0 0-1.3-1.3L2.5 12l6.3-2.1a2 2 0 0 0 1.3-1.3z"/>'),
  send:   _ico('<line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>'),
  pause:  _fill('<rect x="6" y="5" width="4" height="14" rx="1.2"/><rect x="14" y="5" width="4" height="14" rx="1.2"/>'),
  fire:   _fill('<path d="M13 2l-9 12h6l-1 8 9-12h-6l1-8z"/>'),
  trash:  _ico('<polyline points="3 6 21 6"/><path d="M19 6l-.9 13a2 2 0 0 1-2 1.9H7.9a2 2 0 0 1-2-1.9L5 6"/><path d="M9 6V4a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2"/>'),
  launch: _ico('<line x1="5" y1="22" x2="5" y2="3"/><path d="M5 3.5h12.5l-2.2 4.5 2.2 4.5H5"/>'),
  edit:   _ico('<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>'),
  check:  _ico('<polyline points="20 6 9 17 4 12"/>'),
  x:      _ico('<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>'),
};

function icon(name) {
  const span = h('span', { class: 'ic' });
  span.innerHTML = ICONS[name] || '';
  return span;
}

// ---- API -------------------------------------------------------------

class ApiError extends Error {
  constructor(status, body) {
    super(body.error || `HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

// when the server runs with --token, fetches carry it as a header and
// URL-borne channels (SSE, downloads) carry it as ?token=
let adminToken = localStorage.getItem('admin_token') || '';
const withTok = (url) =>
  adminToken ? url + (url.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(adminToken) : url;

async function api(path, { method = 'GET', body } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (adminToken) headers['Authorization'] = 'Bearer ' + adminToken;
  const res = await fetch(path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) {
    const t = prompt('This admin-ui requires its token (the --token value):');
    if (t) {
      adminToken = t.trim();
      localStorage.setItem('admin_token', adminToken);
      location.reload(); // re-open SSE streams with the token
      return new Promise(() => {}); // reload is imminent
    }
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(res.status, data);
  return data;
}

function toast(msg, bad = false) {
  const el = h('div', { class: 'toast' + (bad ? ' bad' : '') }, msg);
  document.getElementById('toasts').append(el);
  setTimeout(() => el.remove(), 4200);
}

const fail = (e) => toast(e.message || String(e), true);

// ---- misc ------------------------------------------------------------

function timeAgo(iso) {
  if (!iso) return '—';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${s | 0}s ago`;
  if (s < 3600) return `${(s / 60) | 0}m ago`;
  if (s < 86400) return `${(s / 3600) | 0}h ago`;
  return `${(s / 86400) | 0}d ago`;
}

// human timestamp, local time: "15:45" today, "Jun 12 · 15:45" this
// year, "Jun 12, 2025 · 15:45" otherwise. Put the raw ISO in title.
function fmtWhen(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return iso || '';
  const now = new Date();
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  if (d.toDateString() === now.toDateString()) return time;
  const sameYear = d.getFullYear() === now.getFullYear();
  const day = d.toLocaleDateString([], sameYear
    ? { month: 'short', day: 'numeric' }
    : { year: 'numeric', month: 'short', day: 'numeric' });
  return `${day} · ${time}`;
}

function timeUntil(iso) {
  const s = Math.max(0, (new Date(iso).getTime() - Date.now()) / 1000);
  if (s < 60) return `in ${Math.ceil(s)}s`;
  if (s < 3600) return `in ${Math.round(s / 60)}m`;
  return `in ${Math.round(s / 3600)}h`;
}

function fmtSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1048576).toFixed(1)} MB`;
}

const firstLine = (s) => (typeof s === 'string' ? s.split('\n', 1)[0] : '');
const go = (hash) => { location.hash = hash; };

function parseKV(text) {
  const out = {};
  for (const line of (text || '').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
  }
  return out;
}

const kvText = (m) => Object.entries(m || {}).map(([k, v]) => `${k}=${v}`).join('\n');

// ---- live fleet state ---------------------------------------------------

let fleet = [];
let overseerName = 'overseer';
let onFleetChange = () => {};
let onRunFinished = () => {}; // the agent page hooks this to refresh

const events = new EventSource(withTok('/api/events'));
events.addEventListener('fleet', (e) => {
  fleet = JSON.parse(e.data).agents || [];
  onFleetChange();
});
// failed runs are announced fleet-wide the moment they finish — a small
// red chip in a side rail is too easy to miss
events.addEventListener('run', (e) => {
  const r = JSON.parse(e.data);
  if (typeof r.exit_code === 'number' && r.exit_code !== 0) {
    const why = r.exit_code === 75 ? ' (session was busy)' : r.exit_code === 78 ? ' (session conflict)' : '';
    toast(`${r.agent}: run failed · exit ${r.exit_code}${why} — see its log`, true);
  }
  onRunFinished(r);
});
api('/api/health').then((d) => { overseerName = d.overseer || 'overseer'; }, () => {});
api('/api/agents').then((d) => { if (!fleet.length) { fleet = d.agents; onFleetChange(); } }, () => {});

function statusOf(a) {
  if (a.running) return { cls: 'run', label: `running · pid ${a.pid}` };
  if (a.session_state === 'conflict') return { cls: 'bad', label: 'conflict · exit 78' };
  if (a.session_state === 'missing') return { cls: 'warn', label: 'no session yet' };
  return { cls: '', label: 'idle' };
}

// ---- layer (modal / sheet) ------------------------------------------------

const layer = () => document.getElementById('layer');

function openModal(...kids) {
  const veil = h('div', { class: 'veil', onclick: (e) => e.target === veil && close() },
    h('div', { class: 'modal' }, ...kids));
  const close = () => veil.remove();
  const esc = (e) => { if (e.key === 'Escape') { close(); window.removeEventListener('keydown', esc); } };
  window.addEventListener('keydown', esc);
  layer().append(veil);
  return close;
}

function openSheet(barKids, bodyEl) {
  layer().querySelector('.sheet')?.remove();
  const sheet = h('div', { class: 'sheet' },
    h('div', { class: 'bar' }, ...barKids,
      h('span', { style: 'margin-left:auto' }),
      h('button', { class: 'ghost sm', title: 'close', onclick: () => sheet.remove() }, icon('x'))),
    bodyEl);
  layer().append(sheet);
  return sheet;
}

// ---- shell & router ----------------------------------------------------------

const app = () => document.getElementById('app');

function topbar(...right) {
  return h('header', { class: 'top' },
    h('div', { class: 'brand', onclick: () => go('#/') },
      h('div', { class: 'mark' }), h('b', {}, 'spirit'), h('span', {}, 'admin')),
    h('div', { class: 'grow' }),
    ...right);
}

function route() {
  const m = location.hash.match(/^#\/agent\/([a-z0-9-]+)/);
  return m ? { page: 'agent', name: m[1] } : { page: 'fleet' };
}

function render() {
  layer().replaceChildren();
  const r = route();
  if (r.page === 'agent') renderAgent(r.name);
  else renderFleet();
}
window.addEventListener('hashchange', render);
document.addEventListener('DOMContentLoaded', render);
