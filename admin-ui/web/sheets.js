// sheets: the bottom drawers — live log tail, and the workspace
// browser with text-file editing (the "patch agent.sh from the UI"
// power; session files are refused by the server, they have /session).
'use strict';

function openLog(name) {
  const pre = h('pre', {}, '(connecting…)');
  openSheet([h('b', {}, 'agent.log'), h('span', {}, name), h('span', { class: 'chip ok' }, 'following')], pre);
  const src = new EventSource(`/api/agents/${name}/log?follow=1`);
  let text = '';
  src.addEventListener('log', (e) => {
    text = (text + JSON.parse(e.data)).slice(-100000);
    pre.textContent = text || '(log is empty)';
    pre.scrollTop = pre.scrollHeight;
  });
  const obs = new MutationObserver(() => {
    if (!document.body.contains(pre)) { src.close(); obs.disconnect(); }
  });
  obs.observe(layer(), { childList: true, subtree: true });
}

function openFiles(name) {
  const list = h('div', { class: 'list' });
  const view = h('div', { class: 'view' });
  const crumbs = h('span', {});
  openSheet([h('b', {}, 'workspace'), crumbs],
    h('div', { class: 'cols' }, list, view));

  setKids(view, h('pre', {}, 'pick a file'));

  async function show(rel) {
    try {
      const d = await api(`/api/agents/${name}/file?path=${encodeURIComponent(rel)}`);
      if (d.binary) {
        setKids(view, h('pre', {}, `binary file · ${fmtSize(d.size)}`));
        return;
      }
      const content = (d.truncated ? `… first 256 KiB of ${fmtSize(d.size)} …\n\n` : '') + (d.content || '');
      const editable = !d.truncated && !rel.includes('.jsonl');
      setKids(view,
        h('div', { class: 'viewbar' },
          h('span', { class: 'mono' }, rel),
          h('span', { style: 'margin-left:auto' }),
          editable && h('button', { class: 'sm', onclick: () => edit(rel, d.content || '') }, '✎ edit')),
        h('pre', {}, content || '(empty file)'));
    } catch (e) { fail(e); }
  }

  function edit(rel, content) {
    const ta = h('textarea', { class: 'mono', spellcheck: 'false' }, content);
    setKids(view,
      h('div', { class: 'viewbar' },
        h('span', { class: 'mono' }, `${rel} — editing`),
        h('span', { style: 'margin-left:auto' }),
        h('button', { class: 'sm', onclick: () => show(rel) }, 'cancel'),
        h('button', { class: 'sm pri', onclick: async () => {
          try {
            const r = await api(`/api/agents/${name}/file?path=${encodeURIComponent(rel)}`, { method: 'PUT', body: { content: ta.value } });
            toast(`saved${r.backup ? ` · previous kept as ${r.backup}` : ''}`);
            show(rel);
          } catch (e) { fail(e); }
        } }, 'save')),
      ta);
    ta.focus();
  }

  async function ls(rel) {
    setKids(crumbs, h('a', { class: 'lnk mono', onclick: () => ls('') }, `agents/${name}`),
      rel.split('/').filter(Boolean).map((part, i, all) =>
        h('span', { class: 'mono' }, ' / ', h('a', { class: 'lnk', onclick: () => ls(all.slice(0, i + 1).join('/')) }, part))));
    try {
      const d = await api(`/api/agents/${name}/files?path=${encodeURIComponent(rel)}`);
      setKids(list,
        rel && h('div', { class: 'frow', onclick: () => ls(rel.split('/').slice(0, -1).join('/')) }, '↩ ..'),
        d.files.length === 0 && h('div', { class: 'frow' }, '(empty)'),
        d.files.map((f) => h('div', { class: 'frow', onclick: () => (f.dir ? ls(f.path) : show(f.path)) },
          h('span', {}, f.dir ? `▸ ${f.name}/` : f.name),
          !f.dir && h('span', { class: 'sz' }, fmtSize(f.size)))));
    } catch (e) { fail(e); }
  }
  void ls('');
}
