// fleet screen: live agent grid + the three fleet-wide panels
// (schedules, templates, teams) and their modals.
'use strict';

function renderFleet() {
  onFleetChange = renderFleetBody;
  onRunFinished = () => {}; // unhook the agent page's listener
  app().replaceChildren(
    topbar(
      h('button', { onclick: openOverseer, title: 'the fleet-managing agent' }, icon('spark'), 'Overseer'),
      h('button', { class: 'pri', onclick: () => newAgentModal() }, icon('plus'), 'New agent'),
    ),
    h('div', { class: 'page', id: 'fleet-body' }),
  );
  renderFleetBody();
  loadSchedules();
  loadTemplates();
  loadTeams();
}

// the three panels live outside the re-render (SSE updates the grid
// every second; the panels reload only after their own actions)
function panelKeep(id) {
  return document.getElementById(id) || h('div', { class: 'panel', id });
}

function renderFleetBody() {
  const body = document.getElementById('fleet-body');
  if (!body) return;
  const running = fleet.filter((a) => a.running).length;
  const trouble = fleet.filter((a) => a.session_state === 'conflict').length;

  setKids(body,
    h('div', { class: 'stats' },
      h('div', {}, h('b', {}, String(fleet.length)), 'agents'),
      h('div', { class: 'ok' }, h('b', {}, String(running)), 'running'),
      h('div', {}, h('b', {}, String(fleet.length - running - trouble)), 'idle'),
      h('div', { class: 'bad' }, h('b', {}, String(trouble)), 'conflicts'),
    ),
    fleet.length === 0
      ? h('div', { class: 'empty' }, 'No agents yet — create one, or drop a folder with agent.sh into the agents root.')
      // overseer pinned first — it manages the rest, so it leads the grid
      : h('div', { class: 'grid' }, [...fleet].sort((a, b) =>
          (b.name === overseerName) - (a.name === overseerName)).map(agentCard)),
    h('h2', {}, 'Schedules'), panelKeep('sched-panel'),
    h('h2', {}, 'Templates'), panelKeep('tmpl-panel'),
    h('h2', {}, 'Teams'), panelKeep('team-panel'),
  );
}

function agentCard(a) {
  const st = statusOf(a);
  const quote = a.session_state === 'conflict'
    ? h('div', { class: 'quote alert' }, `${(a.conflicts || []).length} session files — refuses to run until one remains`)
    : a.session_state === 'missing'
      ? h('div', { class: 'quote soft' }, 'will self-seed a minimal prompt on first run')
      : h('div', { class: 'quote' }, a.last_reply ? `“${a.last_reply}”` : '');

  const isOverseer = a.name === overseerName;
  return h('div', { class: 'card' + (isOverseer ? ' overseer' : ''), onclick: () => go(`#/agent/${a.name}`) },
    h('div', { class: 'hd' },
      h('span', { class: 'dot ' + st.cls }),
      h('b', {}, a.name),
      isOverseer && h('span', { class: 'pin', title: 'overseer — the fleet-managing agent' }, '✦'),
      h('span', { class: 'who sub' }, st.label)),
    h('div', { class: 'meta' },
      h('span', {}, `${a.msgs} msgs`),
      h('span', {}, `active ${timeAgo(a.last_activity)}`)),
    quote,
    // grid actions stay quick: run/stop + log. Composing a message lives
    // in the agent page's composer (one card-click away).
    h('div', { class: 'acts', onclick: (e) => e.stopPropagation() },
      a.running
        ? h('button', { class: 'sm bad lead', onclick: () => stopAgent(a.name) }, icon('stop'), 'Stop')
        : h('button', { class: 'sm lead', onclick: () => runAgent(a.name) }, icon('run'), 'Run'),
      h('button', { class: 'sm', onclick: () => { go(`#/agent/${a.name}`); setTimeout(() => openLog(a.name), 50); } }, icon('log'), 'Log'),
    ));
}

async function openOverseer() {
  if (fleet.some((a) => a.name === overseerName)) return go(`#/agent/${overseerName}`);
  try {
    const d = await api('/api/overseer', { method: 'POST', body: {} });
    if (d.created) toast(`overseer ${d.agent.name} created — give it its first task`);
    go(`#/agent/${d.agent.name}`);
  } catch (e) { fail(e); }
}

async function stopAgent(name) {
  if (!confirm(`Stop the live run on ${name}?`)) return;
  try { await api(`/api/agents/${name}/stop`, { method: 'POST', body: {} }); toast('stop signal sent'); } catch (e) { fail(e); }
}

// ---- schedules panel ---------------------------------------------------

async function loadSchedules() {
  const panel = document.getElementById('sched-panel');
  if (!panel) return;
  let schedules = [];
  try { schedules = (await api('/api/schedules')).schedules; } catch { return; }

  const rows = schedules.map((s) => h('tr', { style: s.enabled ? '' : 'opacity:.45' },
    h('td', {}, h('button', { class: 'sm ghost', title: s.enabled ? 'pause' : 'resume', onclick: async () => {
      try { await api(`/api/schedules/${s.id}`, { method: 'PUT', body: { enabled: !s.enabled } }); loadSchedules(); } catch (e) { fail(e); }
    } }, icon(s.enabled ? 'pause' : 'run'))),
    h('td', { class: 'strong' }, h('a', { class: 'lnk', onclick: () => go(`#/agent/${s.agent}`) }, s.agent)),
    h('td', { title: s.task }, s.task.length > 60 ? s.task.slice(0, 60) + '…' : s.task),
    h('td', {}, h('span', { class: 'mono' }, s.spec)),
    h('td', {}, s.enabled && s.next_at ? timeUntil(s.next_at) : '—'),
    h('td', { title: s.last_result || '' }, s.last_fired ? `${timeAgo(s.last_fired)} · ${s.last_result || ''}` : 'never'),
    h('td', {},
      h('button', { class: 'sm', title: 'fire now', onclick: async () => {
        try { const r = await api(`/api/schedules/${s.id}/fire`, { method: 'POST', body: {} }); toast(`fired — ${r.result}`); loadSchedules(); } catch (e) { fail(e); }
      } }, icon('fire'), 'fire'),
      ' ',
      h('button', { class: 'sm bad', title: 'delete schedule', onclick: async () => {
        if (!confirm(`Delete schedule #${s.id}?`)) return;
        try { await api(`/api/schedules/${s.id}`, { method: 'DELETE' }); loadSchedules(); } catch (e) { fail(e); }
      } }, icon('trash'))),
  ));

  const agentSel = h('select', {}, fleet.map((a) => h('option', {}, a.name)));
  const taskIn = h('input', { class: 'task', placeholder: 'standing task…' });
  const specIn = h('input', { class: 'spec', value: '@every 1h' });

  setKids(panel,
    schedules.length === 0
      ? h('div', { class: 'empty' }, 'No schedules — give an agent a standing task. Specs: @every 30m, or cron "0 9 * * 1-5" (UTC).')
      : h('table', {},
          h('thead', {}, h('tr', {}, ['', 'agent', 'task', 'spec', 'next', 'last', ''].map((t) => h('th', {}, t)))),
          h('tbody', {}, rows)),
    h('div', { class: 'rowform' },
      agentSel, taskIn, specIn,
      h('button', { class: 'pri', onclick: async () => {
        try {
          await api('/api/schedules', { method: 'POST', body: { agent: agentSel.value, task: taskIn.value, spec: specIn.value } });
          toast('schedule created — arms on the next tick');
          loadSchedules();
        } catch (e) { fail(e); }
      } }, icon('plus'), 'Add')),
  );
}

// ---- templates panel ------------------------------------------------------

let templateCache = []; // shared with the new-agent and team modals

async function loadTemplates() {
  const panel = document.getElementById('tmpl-panel');
  if (!panel) return;
  try { templateCache = (await api('/api/templates')).templates; } catch { return; }

  setKids(panel,
    templateCache.length === 0
      ? h('div', { class: 'empty' }, 'No templates — a template is a session blueprint with {{VAR}} placeholders, rendered at agent creation.')
      : h('table', {},
          h('thead', {}, h('tr', {}, ['name', 'records', 'variables', ''].map((t) => h('th', {}, t)))),
          h('tbody', {}, templateCache.map((t) => h('tr', {},
            h('td', { class: 'strong' }, t.name),
            h('td', {}, String(t.records)),
            h('td', {}, t.vars.length ? t.vars.map((v) => h('span', { class: 'chip', style: 'margin-right:4px' }, v)) : '—'),
            h('td', {},
              h('button', { class: 'sm', title: 'new agent from this template', onclick: () => newAgentModal(t.name) }, icon('plus'), 'use'),
              ' ',
              h('button', { class: 'sm bad', title: 'delete template', onclick: async () => {
                if (!confirm(`Delete template ${t.name}?`)) return;
                try { await api(`/api/templates/${t.name}`, { method: 'DELETE' }); loadTemplates(); } catch (e) { fail(e); }
              } }, icon('trash'))))))),
    h('div', { class: 'rowform' },
      h('span', { class: 'sub' }, 'a template = a session.jsonl blueprint'),
      h('span', { style: 'flex:1' }),
      h('button', { class: 'pri', onclick: newTemplateModal }, icon('plus'), 'New template')),
  );
}

function newTemplateModal() {
  const name = h('input', { placeholder: 'e.g. researcher' });
  const prompt = h('textarea', { style: 'min-height:140px', placeholder: 'You are {{AGENT_NAME}}, a researcher focused on {{TOPIC}}.\nReport findings to files in your folder…' });
  const close = openModal(
    h('h3', {}, 'New template'),
    h('div', { class: 'sub' }, 'the system prompt becomes the blueprint; {{VARS}} are asked for at creation ({{AGENT_NAME}} is automatic)'),
    h('div', { class: 'field' }, h('label', {}, 'name'), name),
    h('div', { class: 'field' }, h('label', {}, 'system prompt'), prompt),
    h('div', { class: 'foot' },
      h('button', { onclick: () => close() }, 'Cancel'),
      h('button', { class: 'pri', onclick: async () => {
        try {
          await api('/api/templates', { method: 'POST', body: { name: name.value.trim(), records: [{ role: 'system', content: prompt.value }] } });
          toast(`template ${name.value.trim()} saved`);
          close();
          loadTemplates();
        } catch (e) { fail(e); }
      } }, 'Save')),
  );
}

// ---- teams panel -------------------------------------------------------------

async function loadTeams() {
  const panel = document.getElementById('team-panel');
  if (!panel) return;
  let teams = [];
  try { teams = (await api('/api/teams')).teams; } catch { return; }

  setKids(panel,
    teams.length === 0
      ? h('div', { class: 'empty' }, 'No teams — a team launches a whole composition of template-based agents in one click.')
      : h('table', {},
          h('thead', {}, h('tr', {}, ['name', 'members', ''].map((t) => h('th', {}, t)))),
          h('tbody', {}, teams.map((t) => h('tr', {},
            h('td', { class: 'strong' }, t.name),
            h('td', {}, t.members.map((m) => `${m.count} × ${m.template} (${m.name_pattern})`).join(' · ')),
            h('td', {},
              h('button', { class: 'sm pri', onclick: () => launchTeam(t.name) }, icon('launch'), 'launch'),
              ' ',
              h('button', { class: 'sm', title: 'edit team', onclick: () => teamModal(t) }, icon('edit'), 'edit'),
              ' ',
              h('button', { class: 'sm bad', title: 'delete team', onclick: async () => {
                if (!confirm(`Delete team ${t.name}? (launched agents stay)`)) return;
                try { await api(`/api/teams/${t.name}`, { method: 'DELETE' }); loadTeams(); } catch (e) { fail(e); }
              } }, icon('trash'))))))),
    h('div', { class: 'rowform' },
      h('span', { class: 'sub' }, 'members are created from templates; {{N}} numbers them'),
      h('span', { style: 'flex:1' }),
      h('button', { class: 'pri', onclick: () => teamModal() }, icon('plus'), 'New team')),
  );
}

async function launchTeam(name) {
  if (!confirm(`Launch team ${name}? Existing agents with the same names are skipped.`)) return;
  try {
    const d = await api(`/api/teams/${name}/launch`, { method: 'POST', body: {} });
    const ok = d.results.filter((r) => r.created).length;
    const bad = d.results.filter((r) => r.error);
    toast(`team ${name}: ${ok}/${d.results.length} created${bad.length ? ` · ${bad.length} failed` : ''}`, bad.length > 0);
    bad.slice(0, 3).forEach((r) => toast(`${r.agent}: ${r.error}`, true));
  } catch (e) { fail(e); }
}

// teamModal edits one team: name + a growable list of member rows.
function teamModal(team) {
  const name = h('input', { placeholder: 'e.g. research-squad', value: team?.name || '' });
  if (team) name.disabled = true;
  const memberList = h('div', {});
  const members = (team?.members || [{}]).map(memberRow);

  function memberRow(m = {}) {
    const tplSel = h('select', {}, templateCache.map((t) => h('option', { selected: t.name === m.template }, t.name)));
    const pattern = h('input', { placeholder: 'worker-{{N}}', value: m.name_pattern || '' });
    const count = h('input', { type: 'number', min: '1', value: String(m.count || 1), style: 'width:64px' });
    const vars = h('input', { placeholder: 'TOPIC=ai, LANG=en', value: Object.entries(m.vars || {}).map(([k, v]) => `${k}=${v}`).join(', ') });
    const task = h('input', { placeholder: 'autostart task (optional)', value: m.task || '' });
    const row = h('div', { class: 'mrow' },
      tplSel, pattern, count, vars, task,
      h('button', { class: 'sm ghost', title: 'remove member', onclick: () => { members.splice(members.indexOf(entry), 1); paint(); } }, icon('x')));
    const entry = {
      row,
      value: () => ({
        template: tplSel.value,
        name_pattern: pattern.value.trim(),
        count: Math.max(1, Number(count.value) || 1),
        vars: parseKV(vars.value.replaceAll(',', '\n')),
        task: task.value.trim(),
      }),
    };
    return entry;
  }

  function paint() {
    setKids(memberList, members.map((m) => m.row),
      h('button', { class: 'sm ghost', onclick: () => { members.push(memberRow()); paint(); } }, icon('plus'), 'member'));
  }
  paint();

  if (templateCache.length === 0) {
    toast('create a template first — team members are template-based', true);
    return;
  }
  const close = openModal(
    h('h3', {}, team ? `Edit team — ${team.name}` : 'New team'),
    h('div', { class: 'sub' }, 'each member: template → count agents named by the pattern ({{N}} = number), with vars and an optional first task'),
    h('div', { class: 'field' }, h('label', {}, 'name'), name),
    h('div', { class: 'field' }, h('label', {}, 'members'), memberList),
    h('div', { class: 'foot' },
      h('button', { onclick: () => close() }, 'Cancel'),
      h('button', { class: 'pri', onclick: async () => {
        try {
          await api('/api/teams', { method: 'POST', body: { name: name.value.trim(), members: members.map((m) => m.value()) } });
          toast('team saved');
          close();
          loadTeams();
        } catch (e) { fail(e); }
      } }, 'Save team')),
  );
}

// ---- agent modals ----------------------------------------------------------

function newAgentModal(presetTemplate) {
  const name = h('input', { placeholder: 'e.g. researcher-2' });
  const tplSel = h('select', {},
    h('option', { value: '' }, 'none — write a system prompt (or self-seed)'),
    templateCache.map((t) => h('option', { selected: t.name === presetTemplate }, t.name)));
  const varBox = h('div', {});
  const prompt = h('textarea', { placeholder: 'You are …  (left empty, the agent self-seeds a minimal prompt on first run)' });
  const env = h('textarea', { placeholder: 'MODEL=gpt-5.5-mini\nMAX_TURNS=30' });
  const task = h('input', { placeholder: 'optional — starts a run right after creation' });
  const promptField = h('div', { class: 'field' }, h('label', {}, 'system prompt'), prompt);

  const varInputs = {};
  function syncTemplate() {
    const t = templateCache.find((x) => x.name === tplSel.value);
    promptField.hidden = !!t;
    setKids(varBox, !t ? [] : t.vars.filter((v) => v !== 'AGENT_NAME').map((v) => {
      varInputs[v] = varInputs[v] || h('input', { placeholder: v });
      return h('div', { style: 'margin-bottom:6px' }, varInputs[v]);
    }));
  }
  tplSel.addEventListener('change', syncTemplate);

  const close = openModal(
    h('h3', {}, 'New agent'),
    h('div', { class: 'sub' }, 'creates the folder, installs agent.sh, authors the session'),
    h('div', { class: 'field' }, h('label', {}, 'name'), name,
      h('div', { class: 'note' }, 'lowercase a-z 0-9 dashes — becomes the folder and AGENT_NAME')),
    h('div', { class: 'field' }, h('label', {}, 'template'), tplSel, h('div', { style: 'margin-top:8px' }, varBox)),
    promptField,
    h('div', { class: 'field' }, h('label', {}, 'env overrides (profile.env)'), env,
      h('div', { class: 'note' }, 'one KEY=VALUE per line; LLM_API_KEY always comes from the server env')),
    h('div', { class: 'field' }, h('label', {}, 'first task'), task),
    h('div', { class: 'foot' },
      h('button', { onclick: () => close() }, 'Cancel'),
      h('button', { class: 'pri', onclick: async () => {
        try {
          const useTpl = tplSel.value !== '';
          const vars = {};
          for (const [k, el] of Object.entries(varInputs)) vars[k] = el.value;
          const d = await api('/api/agents', { method: 'POST', body: {
            name: name.value.trim(),
            template: useTpl ? tplSel.value : undefined,
            vars: useTpl ? vars : undefined,
            records: !useTpl && prompt.value.trim() ? [{ role: 'system', content: prompt.value }] : [],
            env: parseKV(env.value),
            autostart_task: task.value.trim() || undefined,
          } });
          toast(`agent ${d.agent.name} created${d.started ? ' and started' : ''}`);
          close();
          go(`#/agent/${d.agent.name}`);
        } catch (e) { fail(e); }
      } }, 'Create')),
  );
  syncTemplate();
  name.focus();
}

// run = one wake, no prompt: the agent processes queued messages and
// continues its standing work. Content reaches an agent through the
// composer on its detail page (a card-click away).
async function runAgent(name) {
  try {
    await api(`/api/agents/${name}/run`, { method: 'POST', body: {} });
    toast(`run started on ${name}`);
  } catch (e) {
    if (e.status === 409) toast('agent is mid-run — queue a message from its page instead', true);
    else fail(e);
  }
}
