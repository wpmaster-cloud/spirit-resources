// agent screen: the session editor. Unedited records keep _raw and
// round-trip byte-perfect; saves carry base_etag+base_size so pure
// concurrent appends rebase server-side; appending via the composer is
// the always-safe channel, even mid-run.
'use strict';

const ROLE_ICONS = { system: '✦', user: '❯', assistant: '✳', tool: '⚙' };
const roleIcon = (r) => h('span', { class: 'ri' }, ROLE_ICONS[r] || '·');

function renderAgent(name) {
  let doc = null;          // last loaded session doc
  let rows = [];           // [{data, dirty}]
  let dirty = false;
  let alive = true;

  const statusEl = h('span', { class: 'status' });
  const actionsEl = h('span', {});
  const threadEl = h('div', { class: 'thread' });
  const bannerEl = h('div', {});
  const runBannerEl = h('div', {});
  const metaEl = h('div', { class: 'metabar' });
  const saveBtn = h('button', { class: 'pri', disabled: true, onclick: () => save() }, 'Save');
  let dismissedRun = Number(sessionStorage.getItem(`dismissed-run-${name}`)) || 0;

  onFleetChange = updateHeader;
  onRunFinished = (r) => {
    if (r.agent !== name) return;
    renderMeta(); // a finished run always changes the meta strip
    if (!dirty) void load();
  };

  app().replaceChildren(
    topbar(
      h('button', { onclick: () => openFiles(name) }, '⌗ Files'),
      h('button', { onclick: () => openLog(name) }, icon('log'), 'Log'),
      actionsEl,
      saveBtn,
    ),
    h('div', { class: 'page' },
      h('div', { style: 'display:flex;align-items:center;gap:12px;margin-bottom:18px' },
        h('span', { class: 'crumb' }, h('a', { onclick: () => go('#/') }, 'fleet'), ' / '),
        h('h1', {}, name),
        statusEl),
      metaEl,
      bannerEl, runBannerEl, threadEl, composer()),
  );

  function fleetAgent() { return fleet.find((a) => a.name === name); }

  function updateHeader() {
    const a = fleetAgent();
    const st = a ? statusOf(a) : { cls: '', label: '…' };
    setKids(statusEl, h('span', { class: 'dot ' + st.cls }), st.label, dirty && h('span', { class: 'chip warn' }, 'unsaved'));
    setKids(actionsEl,
      a?.running
        ? h('button', { class: 'bad', onclick: () => stopAgent(name) }, icon('stop'), 'Stop')
        : h('button', { onclick: () => runAgent(name) }, icon('run'), 'Run'));
    if (a?.session_state === 'conflict') renderConflict(a);
    else if (bannerEl.dataset.conflict) { bannerEl.dataset.conflict = ''; bannerEl.replaceChildren(); void load(); }
  }

  function setDirty(v) {
    dirty = v;
    saveBtn.disabled = !v;
    updateHeader();
  }

  async function load() {
    try {
      const d = await api(`/api/agents/${name}/session`);
      doc = d;
      rows = d.messages.map((m) => ({ data: m, dirty: false }));
      setDirty(false);
      renderThread();
      renderMeta();
    } catch (e) {
      if (e.status !== 409) fail(e); // 409 = exit-78 conflict; the banner handles it
    }
  }

  function renderConflict(a) {
    if (bannerEl.dataset.conflict === 'y') return;
    bannerEl.dataset.conflict = 'y';
    threadEl.replaceChildren();
    setKids(bannerEl, h('div', { class: 'banner' },
      h('b', {}, `exit-78: ${(a.conflicts || []).length} session files in one folder. `),
      'agent.sh refuses to run until one remains. Pick the survivor — the others are renamed aside, never deleted.',
      (a.conflicts || []).map((c) => {
        const base = c.split('/').pop();
        return h('div', { class: 'row' },
          h('span', { class: 'mono' }, base),
          h('button', { class: 'sm pri', onclick: async () => {
            if (!confirm(`Keep ${base} and set the others aside?`)) return;
            try {
              const r = await api(`/api/agents/${name}/resolve-conflict`, { method: 'POST', body: { keep: base } });
              toast(`kept ${r.kept}`);
            } catch (e) { fail(e); }
          } }, 'keep this one'));
      })));
  }

  // ---- thread ----

  function renderThread() {
    if (!doc) return;
    setKids(threadEl,
      doc.locked && h('div', { class: 'banner warn' },
        h('b', {}, `locked by live run (pid ${doc.lock_owner}) — `),
        'full saves need force; queueing below is always safe'),
      (doc.errors || []).length > 0 && h('div', { class: 'banner' },
        `${doc.errors.length} unparseable line(s) on disk — kept, but a save would drop them`),
      !doc.exists && rows.length === 0
        ? h('div', { class: 'empty' }, 'No session yet — the agent self-seeds on first run, or append a message below.')
        : rows.map((r, i) => msgCard(r, i)),
    );
  }

  function msgCard(row, idx) {
    const m = row.data;
    const role = typeof m.role === 'string' ? m.role : '?';
    const content = typeof m.content === 'string' ? m.content : '';
    const calls = Array.isArray(m.tool_calls) ? m.tool_calls : [];
    let editing = false;

    // Clicking the message text opens the editor straight away — no
    // intermediate read view, no edit button. Interactive bits inside the
    // editor stopPropagation so they don't re-trigger this.
    const card = h('div', { class: 'msg' + (row.dirty ? ' dirty' : ''), onclick: () => { if (!editing) { editing = true; paint(); } } });

    function summary() {
      if (firstLine(content)) return firstLine(content);
      if (calls.length) return calls.map(callSummary).join(' · ');
      if (role === 'tool') return firstLine(prettyToolResult(content)) || '(empty result)';
      return '(empty)';
    }

    function paint() {
      setKids(card,
        h('div', { class: 'hd' },
          h('span', { class: 'role ' + role }, roleIcon(role), role),
          m.ephemeral === true && h('span', { class: 'eph' }, 'ephemeral'),
          calls.length > 0 && h('span', { class: 'sub' }, `⚙ ${calls.length} call(s)`),
          typeof m.tool_call_id === 'string' && h('span', { class: 'sub mono' }, `↳ ${m.tool_call_id.slice(0, 12)}`),
          h('span', { class: 'when', title: typeof m.created_at === 'string' ? m.created_at : '' },
            typeof m.created_at === 'string' ? fmtWhen(m.created_at) : '')),
        !editing && h('div', { class: 'sum' }, summary()),
        editing && editor(),
      );
    }

    function editor() {
      let raw = false;
      const roleSel = h('select', {}, ['system', 'user', 'assistant', 'tool'].map((r) =>
        h('option', { selected: r === role }, r)));
      const eph = h('input', { type: 'checkbox', checked: m.ephemeral === true });
      const ta = h('textarea', {}, content);
      const box = h('div', { class: 'editor', onclick: (e) => e.stopPropagation() });

      const rawText = () => {
        const { _raw, ...rest } = m;
        return JSON.stringify(rest, null, 2);
      };

      function paintEditor() {
        setKids(box,
          raw
            ? h('textarea', { class: 'mono', style: 'min-height:160px', spellcheck: 'false' }, rawText())
            : [h('div', { class: 'row' }, roleSel,
                h('label', { class: 'chk', title: 'compaction may drop it' }, eph, 'ephemeral')), ta,
               calls.map((c) => h('div', { class: 'call' }, h('div', { class: 'nm' }, c.function?.name || 'call'), prettyArgs(c.function?.arguments)))],
          h('div', { class: 'row' },
            h('button', { class: 'sm ghost', onclick: () => { raw = !raw; paintEditor(); } }, raw ? 'form' : '{} raw JSON'),
            h('button', { class: 'sm', title: 'move up', onclick: () => move(idx, -1) }, '↑'),
            h('button', { class: 'sm', title: 'move down', onclick: () => move(idx, 1) }, '↓'),
            h('button', { class: 'sm', title: 'insert a new record below', onclick: () => {
              rows.splice(idx + 1, 0, { data: { kind: 'message', role: 'user', content: '' }, dirty: true });
              setDirty(true); renderThread();
            } }, icon('plus'), 'insert'),
            h('button', { class: 'sm bad', title: 'delete record', onclick: () => {
              if ((m.tool_calls !== undefined || m.tool_call_id !== undefined) &&
                  !confirm('This record is part of a tool_calls pair — deleting one side breaks the session. Delete anyway?')) return;
              rows.splice(idx, 1); setDirty(true); renderThread();
            } }, icon('trash')),
            h('span', { style: 'flex:1' }),
            h('button', { class: 'sm', onclick: () => { editing = false; paint(); } }, 'cancel'),
            h('button', { class: 'sm pri', onclick: () => {
              let updated;
              if (raw) {
                try {
                  updated = JSON.parse(box.querySelector('textarea').value);
                  if (!updated || typeof updated !== 'object' || Array.isArray(updated)) throw new Error('not an object');
                } catch (e2) { return toast(`invalid JSON: ${e2.message}`, true); }
              } else {
                updated = { ...m, role: roleSel.value, content: ta.value };
                if (eph.checked) updated.ephemeral = true;
                else delete updated.ephemeral;
              }
              delete updated._raw; // edited: the server re-marshals
              rows[idx] = { data: updated, dirty: true };
              setDirty(true); renderThread();
            } }, 'done')));
      }
      paintEditor();
      return box;
    }

    paint();
    return card;
  }

  function move(idx, delta) {
    const j = idx + delta;
    if (j < 0 || j >= rows.length) return;
    [rows[idx], rows[j]] = [rows[j], rows[idx]];
    setDirty(true);
    renderThread();
  }

  async function save(force = false) {
    if (!doc) return;
    const messages = rows.map((r) => r.data);
    try {
      const res = await api(`/api/agents/${name}/session`, {
        method: 'POST',
        body: { messages, base_etag: doc.etag, base_size: doc.size, force },
      });
      toast(`saved ${res.count} records${res.rebased ? ` · rebased ${res.rebased} append(s)` : ''}`);
      (res.warnings || []).forEach((w) => toast(w, true));
      await load();
    } catch (e) {
      if (e.status === 409 && confirm(`Session locked by live run (pid ${e.body.lock_owner}). Force the save?`)) await save(true);
      else if (e.status === 412) { toast('session changed underneath — reloaded', true); await load(); }
      else fail(e);
    }
  }

  function composer() {
    const roleSel = h('select', {}, ['user', 'system', 'assistant'].map((r) => h('option', {}, r)));
    const ta = h('textarea', { placeholder: `Message ${name}… queueing is always safe, even mid-run` });
    const now = h('input', { type: 'checkbox', checked: true });
    const send = async () => {
      if (!ta.value.trim()) return;
      try {
        const d = await api(`/api/agents/${name}/messages`, {
          method: 'POST',
          body: { role: roleSel.value, content: ta.value, deliver_now: now.checked },
        });
        toast(`appended${d.nudge_armed ? ' · delivery armed' : ''}`);
        if (d.warning) toast(d.warning, true);
        ta.value = '';
        await load();
      } catch (e) { fail(e); }
    };
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
    });
    return h('div', { class: 'composer' },
      ta,
      h('div', { class: 'bar' },
        roleSel,
        h('span', { class: 'hint' }, 'Enter = append · Shift+Enter = newline'),
        h('label', { class: 'chk', title: 'auto-run the moment the agent is idle' }, now, 'deliver now'),
        h('button', { class: 'pri', onclick: send }, icon('send'), 'Append')));
  }

  // ---- meta strip ----
  // The old two-column side rail, folded into one compact bar above the
  // thread: session facts inline on the left, the latest runs on the right,
  // and the rarely-touched bits (profile, backups, archive) behind disclosures.

  async function renderMeta() {
    let profile = {}, runs = [], backups = [];
    try {
      const [d1, d2, d3] = await Promise.all([
        api(`/api/agents/${name}`),
        api(`/api/runs?agent=${name}&limit=8`),
        api(`/api/agents/${name}/backups`),
      ]);
      profile = d1.profile || {};
      runs = d2.runs || [];
      backups = (d3.backups || []).slice(0, 8);
    } catch { /* meta is best-effort */ }

    paintRunBanner(runs[0]);

    const profTa = h('textarea', { placeholder: 'MODEL=…\nMAX_TURNS=…' }, kvText(profile));

    const disc = (title, ...kids) =>
      h('details', { class: 'disc' }, h('summary', {}, title), h('div', { class: 'disc-body' }, ...kids));

    setKids(metaEl,
      h('div', { class: 'meta-facts' },
        h('span', { class: 'f' }, h('span', { class: 'k' }, 'session'),
          h('span', { class: 'v mono' }, doc?.session_file?.split('/').pop() || '—')),
        h('span', { class: 'f' }, h('span', { class: 'v' }, String(rows.length)), h('span', { class: 'k' }, 'records')),
        h('span', { class: 'f' }, h('span', { class: 'v' }, doc ? fmtSize(doc.size) : '—')),
        h('span', { class: 'meta-runs' },
          runs.length === 0
            ? h('span', { class: 'sub' }, 'no runs yet')
            : runs.slice(0, 3).map((r) => h('span', { class: 'run', title: `${r.task || r.source} · ${timeAgo(r.started_at)}` },
                h('span', { class: 'chip ' + exitCls(r) }, exitLabel(r)),
                h('span', { class: 'sub' }, timeAgo(r.started_at)))))),
      h('div', { class: 'meta-tools' },
        disc('Profile',
          h('div', { class: 'stack' }, profTa,
            h('button', { class: 'sm', onclick: async () => {
              try { await api(`/api/agents/${name}/profile`, { method: 'PUT', body: parseKV(profTa.value) }); toast('profile saved'); } catch (e) { fail(e); }
            } }, 'Save profile'))),
        disc(`Backups${backups.length ? ` (${backups.length})` : ''}`,
          backups.length === 0
            ? h('div', { class: 'sub' }, 'appear after the first save or compaction')
            : backups.map((b) => h('div', { class: 'line-item' },
                h('span', { class: 'grow mono', title: b.name }, b.name.replace(/^.*\.bak\./, '')),
                h('span', { class: 'sub' }, fmtSize(b.size)),
                h('button', { class: 'sm', title: 'restore (the present is backed up first)', onclick: async () => {
                  if (!confirm('Restore this backup? The present is backed up first.')) return;
                  try {
                    const r = await api(`/api/agents/${name}/backups/${encodeURIComponent(b.name)}/restore`, { method: 'POST', body: {} });
                    toast(`restored ${r.count} records`);
                    await load();
                  } catch (e) { fail(e); }
                } }, '⤺')))),
        h('span', { style: 'flex:1' }),
        h('button', { class: 'sm bad', onclick: async () => {
          if (!confirm(`Archive ${name}? Moves the folder to .archive/ (no hard delete).`)) return;
          try { const r = await api(`/api/agents/${name}/archive`, { method: 'POST', body: {} }); toast(`archived to ${r.archived_to}`); go('#/'); } catch (e) { fail(e); }
        } }, '⌫ Archive agent')),
    );
  }

  // paintRunBanner shows the latest run when it FAILED: exit code plus
  // that run's slice of agent.log, dismissible until a newer failure.
  async function paintRunBanner(last) {
    if (!last || typeof last.exit_code !== 'number' || last.exit_code === 0 || last.id <= dismissedRun) {
      runBannerEl.replaceChildren();
      return;
    }
    let tail = '';
    try {
      const seg = await api(`/api/agents/${name}/log?from=${last.log_start}&to=${last.log_end ?? -1}`);
      tail = (seg.content || '').split('\n').filter(Boolean).slice(-8).join('\n');
    } catch { /* banner still useful without the log */ }
    setKids(runBannerEl, h('div', { class: 'banner' },
      h('div', { style: 'display:flex;align-items:baseline;gap:10px' },
        h('b', {}, `last run failed — ${exitLabel(last)}`),
        h('span', { class: 'sub' }, `${last.task || last.source} · ${timeAgo(last.started_at)}`),
        h('span', { style: 'margin-left:auto' }),
        h('button', { class: 'sm', onclick: () => openLog(name) }, 'full log'),
        h('button', { class: 'sm ghost', onclick: () => {
          dismissedRun = last.id;
          sessionStorage.setItem(`dismissed-run-${name}`, String(last.id));
          runBannerEl.replaceChildren();
        } }, 'dismiss')),
      tail && h('pre', { class: 'runtail' }, tail)));
  }

  // live refresh while clean: poll the etag, reload on change
  const poll = setInterval(async () => {
    if (!alive) return clearInterval(poll);
    if (route().page !== 'agent' || dirty) return;
    try {
      const d = await api(`/api/agents/${name}/session`);
      if (dirty) return;
      if (doc && d.etag !== doc.etag) { doc = d; rows = d.messages.map((m) => ({ data: m, dirty: false })); renderThread(); renderMeta(); }
      else doc = d;
    } catch { /* transient */ }
  }, 2500);
  window.addEventListener('hashchange', () => { alive = false; }, { once: true });

  updateHeader();
  void load();
}

// ---- transcript helpers -----------------------------------------------------

function exitLabel(r) {
  if (r.exit_code == null) return r.finished_at ? '?' : 'live';
  if (r.exit_code === 75) return '75 busy';
  if (r.exit_code === 78) return '78 conflict';
  return String(r.exit_code);
}

function exitCls(r) {
  if (r.exit_code == null) return r.finished_at ? '' : 'ok';
  if (r.exit_code === 0) return 'ok';
  if (r.exit_code === 75) return 'warn';
  return 'bad';
}

function callSummary(c) {
  try {
    const args = JSON.parse(c.function?.arguments || '{}');
    if (c.function?.name === 'run_command' && args.command) return `$ ${firstLine(args.command)}`;
  } catch { /* name only */ }
  return c.function?.name || 'call';
}

function prettyArgs(args) {
  if (typeof args !== 'string') return String(args ?? '');
  try {
    const o = JSON.parse(args);
    if (o && typeof o.command === 'string') return `$ ${o.command}`;
    return JSON.stringify(o, null, 2);
  } catch { return args; }
}

function prettyToolResult(content) {
  try {
    const o = JSON.parse(content);
    if (o && typeof o === 'object' && 'output' in o) {
      return `exit ${o.exit_code}${o.timed_out ? ' · TIMED OUT' : ''}${o.truncated ? ' · truncated' : ''}\n${o.output ?? ''}`;
    }
    return JSON.stringify(o, null, 2);
  } catch { return content; }
}
