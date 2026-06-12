# admin-ui — the spirit fleet control plane

One Go binary, zero dependencies, web UI embedded. Point it at a folder of
agents and get: a live fleet dashboard, the session editor (byte-perfect
round-trips, append-aware optimistic saves), run/stop/queue with deliver-now,
live logs, a workspace browser that can edit `agent.sh`, backups restore,
cron schedules, session **templates**, multi-agent **teams**, and the
**overseer** — a fleet-managing agent that operates this very API.

```bash
./admin-ui.sh --root ../../agents        # http://127.0.0.1:8900
```

The launcher runs the first of: a prebuilt `./admin-ui` binary → `go run .` →
a binary downloaded from this repo's GitHub releases (`build.sh` + `gh
release create` publishes them). Flags: `--root --port --host --token`.

## The filesystem is the whole state

- an **agent** is a folder under the root with `agent.sh`; its
  `session-*.jsonl` is its entire memory
- `<agent>/profile.env` — non-secret launch overrides (MODEL, MAX_TURNS…)
- `<root>/.superadmin/schedules.json` — standing tasks (`@every 30m` or
  5-field cron, UTC; busy agents get the task queued + nudged, never dropped)
- `<root>/.superadmin/templates/<name>.jsonl` — session blueprints with
  `{{VAR}}` placeholders, rendered at agent creation
- `<root>/.superadmin/teams.json` — named compositions: members =
  template × count, `{{N}}`-numbered names; one click launches all
- run history is in-memory; `agent.log` and the sessions are the durable record

## Invariants the server enforces

- saves carry the base file's sha256+size; pure-append drift is rebased
  automatically, anything else is a 412
- unedited records round-trip byte-perfect via `_raw`
- every rewrite backs up first; restores back up the present too; nothing is
  ever deleted (archive and conflict-resolution rename aside)
- lock dirs are never touched; exit-78 conflicts are resolved only by a human
  picking the survivor
- `LLM_API_KEY` stays in the process env; the control-plane env
  (SUPERADMIN_API, ADMIN_TOKEN) reaches exactly one agent — the overseer
  (POST /api/overseer creates it)

## API sketch

```
GET  /api/agents                         GET/POST /api/agents/{n}/session
POST /api/agents  {name, template?, vars?, records?, env?, autostart_task?}
POST /api/agents/{n}/messages            {content, deliver_now}   ← always safe
POST /api/agents/{n}/run|stop|archive|resolve-conflict
GET  /api/agents/{n}/log?follow=1        GET /api/runs?agent=
GET  /api/agents/{n}/files|file          PUT /api/agents/{n}/file  (edit agent.sh…)
GET  /api/agents/{n}/backups             POST /api/agents/{n}/backups/{b}/restore
GET|POST /api/templates                  DELETE /api/templates/{name}
GET|POST /api/teams                      POST /api/teams/{name}/launch
GET|POST /api/schedules                  PUT|DELETE /api/schedules/{id} · /fire
GET  /api/events (SSE fleet)             GET /api/health
```
