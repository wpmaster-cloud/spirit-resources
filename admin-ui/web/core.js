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

// ---- API -------------------------------------------------------------

class ApiError extends Error {
  constructor(status, body) {
    super(body.error || `HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(path, {
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
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

new EventSource('/api/events').addEventListener('fleet', (e) => {
  fleet = JSON.parse(e.data).agents || [];
  onFleetChange();
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
      h('button', { class: 'ghost sm', onclick: () => sheet.remove() }, '✕')),
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
