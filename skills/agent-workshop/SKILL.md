---
name: agent-workshop
requires: jq, git
description: >
  Create, command, and deploy more spirit agents. Use whenever the user wants to
  spawn a subagent or helper agent, run several agents on one machine, delegate
  or parallelize work across agents, send a task or message to another agent,
  read another agent's progress or replies, schedule agents with cron, or ship
  an agent as a container (Docker / Kubernetes). Trigger phrases: "subagent",
  "another agent", "spawn an agent", "agent fleet", "delegate", "tell agent X",
  "deploy the agent", "containerize".
---

# Agent Workshop

How to build, talk to, and deploy agents like this one. Read this fully before
spawning or messaging an agent; the invariants at the end prevent corrupted
sessions.

## Anatomy: an agent is a folder

```
agents/researcher/
├── agent.sh                        # the runtime (copy or symlink of this folder's agent.sh)
└── session-researcher-<id>.jsonl  # system prompt + entire conversation; single source of truth
```

Facts you rely on:

- `agent.sh` works out of its own folder, wherever it is invoked from. A
  symlinked `agent.sh` still uses the *symlink's* folder as workspace, so many
  agents can share one script file.
- The session file is discovered, in order: an explicit `SESSION_FILE`, a
  legacy `session.jsonl` (honored forever), else the folder's single
  `session-*.jsonl`. A missing one is self-seeded on first run as
  `session-<AGENT_NAME>-<id>.jsonl` — `AGENT_NAME` defaults to the folder's
  name — so the fastest spawn is: create folder, link script, run it. Several
  `session-*.jsonl` files in one folder are refused with exit **78**; keep
  exactly one, or `--reset`. The first session line is the system prompt;
  author a full session first (below) when the agent needs a real role from
  turn one.
- Config values come from the environment: `AGENT_NAME`, `MODEL`, `BASE_URL`,
  `LLM_API_KEY`, `MAX_TURNS`, `COMMAND_TIMEOUT_SEC`, `COMMAND_MAX_OUTPUT_BYTES`,
  `CONTEXT_COMPACT_TOKENS`, `SESSION_FILE`. If `BASE_URL` / `MODEL` are unset
  they are auto-detected from the API key's prefix (OpenAI, Anthropic,
  OpenRouter, Groq, xAI, NVIDIA, Gemini) or fall back to defaults. API keys
  belong in the environment (or a secret store), never in files you ship or
  commit.
- Only one run per session at a time: while a run is active a `<session>.lock`
  directory exists next to the session file, and a second run exits with code
  **75** (busy — retry later). Appending messages is always allowed.

## Spawn a subagent

```bash
name=researcher        # lowercase a-z, 0-9 and dashes, max 40 chars — agent.sh
                       # normalizes AGENT_NAME to this alphabet, and the admin-ui
                       # fleet scan only sees folders that already match it
mkdir -p "agents/$name"
cp -- agent.sh "agents/$name/agent.sh"          # copy = isolated
# ln -s ../../agent.sh "agents/$name/agent.sh"  # symlink = one script, many agents
chmod +x "agents/$name/agent.sh"

# Author the system prompt. Reuse this folder's prompt as the base so the
# subagent inherits the shell discipline, and put its role on top.
sess=(session*.jsonl)
jq -r -s 'map(select(.role == "system")) | .[0].content' "${sess[0]}" > /tmp/base.txt
{
  cat <<'EOF'
You are Researcher, a focused subagent. Your only job: <one-sentence scope>.
Write your final deliverable to ./outbox.md in your workspace. Keep chat
replies to one short status line. Reply exactly "idle" when nothing is pending.

EOF
  cat /tmp/base.txt
} > /tmp/prompt.txt
jq -nc --rawfile c /tmp/prompt.txt \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{kind:"message", created_at:$t, role:"system", content:$c}' \
  > "agents/$name/session.jsonl"
rm -f /tmp/base.txt /tmp/prompt.txt

# Smoke test
./agents/"$name"/agent.sh "Confirm you are alive: state your role in one line."
```

Authoring to the legacy name `session.jsonl` is fine — it is honored forever.
Skip the authoring step and the agent self-seeds as
`session-<name>-<id>.jsonl` with a minimal prompt instead. Never copy an
existing session file into a new agent unless the user explicitly wants it to
inherit that conversation.

## Give work

```bash
# Blocking: returns when the turn completes; output is printed.
./agents/researcher/agent.sh "Read X, summarize into outbox.md."

# Background: for long tasks. -d detaches and logs to the agent's own
# agent.log — the file the admin-ui log viewer reads, so prefer it over
# hand-rolled nohup to a different file.
./agents/researcher/agent.sh -d "long task"
tail -f agents/researcher/agent.log

# Per-call overrides: cheaper model, higher turn budget, etc.
MODEL=gpt-5.5-mini MAX_TURNS=30 ./agents/researcher/agent.sh "task"
```

For *persistent* non-secret overrides, write `agents/<name>/profile.env`
(`MODEL=...`, one `KEY=value` per line; never `LLM_API_KEY` — keys stay in the
process env). The admin-ui control plane applies it to every run it launches;
`agent.sh` itself does **not** read it, so manual and cron runs must source it:
`set -a; . ./profile.env; set +a; ./agent.sh "task"`.

Exit code 75 means the agent is mid-run. Either wait for the lock, or queue a
message instead (next section) — queuing never blocks and never collides.

## Communicate through the session file

Resolve the agent's session file once (works for legacy and named sessions —
never glob inside a redirection):

```bash
sess=(agents/researcher/session*.jsonl)   # exactly one match on a healthy agent
[ -e "${sess[0]}" ] || { echo "no session file — run the agent once to seed it"; exit 1; }
```

The guard matters: with no session file the glob stays literal, and appending
to it creates a file named `session*.jsonl` — invisible to the agent's own
discovery, so every queued message would be silently lost.

**Queue a task/message** (safe anytime, even mid-run — append only, built with
jq, exact record shape):

```bash
jq -nc \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg c "New instruction: also cover Y. Reply in outbox.md." \
  '{kind:"message", created_at:$t, role:"user", content:$c}' \
  >> "${sess[0]}"
```

Queued messages are processed on the agent's **next run** (its cron wake, or
any one-shot you fire later). To deliver now:

```bash
# check the lock OWNER, not just the dir — a crashed run leaves a stale lock
# (dead pid) that agent.sh takes over on its next start; waiting on the bare
# dir would hang forever
while kill -0 "$(cat "${sess[0]}.lock/pid" 2>/dev/null)" 2>/dev/null; do sleep 5; done
./agents/researcher/agent.sh "Process any pending messages above."
```

**Read its state:**

```bash
# running or idle? (a live pid in the lock = running; a stale lock reads idle)
kill -0 "$(cat "${sess[0]}.lock/pid" 2>/dev/null)" 2>/dev/null && echo running || echo idle

# last substantive reply
jq -r -s '[.[] | select(.role == "assistant" and (.content // "") != "")] | last.content' \
  "${sess[0]}"

# recent activity, one line per record
tail -n 8 "${sess[0]}" \
  | jq -r '.role + ": " + ((.content // "(tool calls)")[0:160])'
```

Exchange large artifacts through files in the agent's folder (`outbox.md`,
`data/*.csv`), not through giant chat messages.

## Fleet on one machine

Ten agents are just ten folders — no daemons, no runtime; an idle agent costs
zero. Suggested layout: `agents/<name>/` per agent, `agent.sh` symlinked from
one canonical copy so upgrades land everywhere at once.

Standing/recurring work goes in cron. Stagger minutes so agents do not hit the
API at the same instant; a wake that finds the agent busy exits 75 harmlessly.

```cron
*/15 * * * *  cd /abs/path/agents/researcher && ./agent.sh "Wake: continue your standing task. If nothing pending, reply exactly: idle." >> cron.log 2>&1
2-59/15 * * * *  cd /abs/path/agents/editor && ./agent.sh "Wake: check for queued messages and continue." >> cron.log 2>&1
```

## When the admin-ui control plane is running

If an admin-ui serves this fleet (default `http://127.0.0.1:8900`; with a
token, add `-H "Authorization: Bearer $ADMIN_TOKEN"`), prefer its API over
raw filesystem operations — it enforces the same invariants you would by
hand, backs up before every rewrite, and auto-rebases concurrent appends:

```bash
# queue a message: validated record, and deliver_now auto-runs the agent
# the moment its lock frees — replaces the append + wait-loop above
curl -s -X POST localhost:8900/api/agents/researcher/messages \
  -d '{"content":"New instruction: also cover Y.","deliver_now":true}'

# standing tasks: replaces raw cron, and a busy agent gets the task
# queued + nudged (queue_if_busy) instead of a wasted exit-75 wake
curl -s -X POST localhost:8900/api/schedules \
  -d '{"agent":"researcher","task":"Wake: continue your standing task.","spec":"@every 15m"}'

# create an agent in one call (authors the session, installs agent.sh)
curl -s -X POST localhost:8900/api/agents \
  -d '{"name":"editor","records":[{"role":"system","content":"You are Editor: ..."}]}'
```

Everything else (`/run`, `/stop`, `/log?follow=1`, `/session`, `/backups`,
templates, teams) is listed in the admin-ui README. The filesystem recipes in
this skill remain correct alongside it — direct appends are exactly what the
server's save path rebases around.

## Containers and Kubernetes

`ops/` in the agent repo (github.com/tomerfooks/spirit) has the full thin
deployment (alpine + bash/curl/jq/rg/git, linux/arm64):
`ops/Dockerfile`, `ops/agent.yaml`, `ops/build-push.sh` (image only),
`ops/deploy.sh` (build + secret + apply). The image bakes in `agent.sh` (plus
the main agent's `session.jsonl`) — **no skills, no UI**. An agent that needs
a skill fetches it on demand from the public resources repo:

```bash
git clone --depth 1 https://github.com/wpmaster-cloud/spirit-resources /work/resources
cp -R /work/resources/skills /work/ && rm -rf /work/resources
cat /work/skills/<name>/SKILL.md
```

The admin-ui control plane is no longer in this repo's tree — its source
lives in the spirit repo and only its compiled binary ships here, as a
release. Fetch it directly when you want the UI:

```bash
curl -fsSL -o /work/admin-ui \
  https://github.com/wpmaster-cloud/spirit-resources/releases/latest/download/admin-ui-linux-arm64 \
  && chmod +x /work/admin-ui
```

Containers are **ephemeral by design**: the agent self-seeds its session on
first run (named after `AGENT_NAME`, set in the manifest) and a pod
replacement is a factory reset. Identity is given the same way as everywhere
else — by manipulating the session file (`kubectl cp` a `session.jsonl` in —
the legacy name is honored — or just message it). Anything durable is the
agent's own job: tell it to commit/push work products to a git remote
(`GIT_TOKEN` is wired in the manifest). Read `ops/agent.yaml`'s header comment
for the deploy/clone/operate commands. The short version:

```bash
ops/build-push.sh                                   # build+push the arm64 image
LLM_API_KEY=... ops/deploy.sh                       # build+push + secret + apply in one go
kubectl apply -f ops/agent.yaml                     # deploy agent "agent-main"
sed 's/agent-main/agent-researcher/g' ops/agent.yaml | kubectl apply -f -   # clone
kubectl exec deploy/agent-main -- /work/agent.sh "task"                     # give work
kubectl exec deploy/agent-main -- sh -c 'tail -n 3 /work/session*.jsonl'    # read state
```

## Invariants (do not break these)

- Build every session line with `jq -nc` / `--rawfile`. Never hand-write JSON.
- Foreign sessions: **append only**. Never edit or delete existing lines of
  another agent's session — assistant `tool_calls` lines and their `tool`
  results are linked by id, and breaking a pair makes the API reject the whole
  session.
- One run per session; respect exit 75 instead of deleting a live lock. A lock
  whose owner pid is dead is taken over automatically — don't clean it by hand.
- One session file per folder. Never create a second `session-*.jsonl` next to
  an existing one — the agent refuses to run (exit 78) until exactly one
  remains.
- A new agent needs its own folder and its own freshly authored session.
- Keep subagent prompts narrow: one role, one deliverable convention, "reply
  idle when nothing pending" — that is what makes cron wakes cheap.
