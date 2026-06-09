---
name: agent-workshop
requires: jq, git
description: >
  Create, command, and deploy more bash agents. Use whenever the user wants to
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
├── agent.sh         # the runtime (copy or symlink of this folder's agent.sh)
└── session.jsonl    # system prompt + entire conversation; single source of truth
```

Facts you rely on:

- `agent.sh` works out of its own folder, wherever it is invoked from. A
  symlinked `agent.sh` still uses the *symlink's* folder as workspace, so many
  agents can share one script file.
- The first `session.jsonl` line is the system prompt. A missing session is
  self-seeded with one minimal line on first run, so the fastest spawn is:
  create folder, link script, run it. Author a full session first (below) when
  the agent needs a real role from turn one.
- Every config value is env-overridable per invocation: `MODEL`, `BASE_URL`,
  `API_KEY`/`BASH_AGENT_API_KEY`/`OPENAI_API_KEY`, `MAX_TURNS`,
  `COMMAND_TIMEOUT_SEC`, `CONTEXT_COMPACT_TOKENS`, `SESSION_FILE`.
- Only one run per session at a time: while a run is active a
  `session.jsonl.lock` directory exists, and a second run exits with code
  **75** (busy — retry later). Appending messages is always allowed.

## Spawn a subagent

```bash
name=researcher
mkdir -p "agents/$name"
cp -- agent.sh "agents/$name/agent.sh"          # copy = isolated
# ln -s ../../agent.sh "agents/$name/agent.sh"  # symlink = one script, many agents
chmod +x "agents/$name/agent.sh"

# Author the system prompt. Reuse this folder's prompt as the base so the
# subagent inherits the shell discipline, and put its role on top.
jq -r -s 'map(select(.role == "system")) | .[0].content' session.jsonl > /tmp/base.txt
{
  cat <<'EOF'
You are Researcher, a focused subagent. Your only job: <one-sentence scope>.
Write your final deliverable to ./outbox.md in your workspace. Keep chat
replies to one short status line. Reply exactly "idle" when nothing is pending.

EOF
  cat /tmp/base.txt
} > /tmp/prompt.txt
jq -nc --rawfile c /tmp/prompt.txt '{kind:"message", role:"system", content:$c}' \
  > "agents/$name/session.jsonl"
rm -f /tmp/base.txt /tmp/prompt.txt

# Smoke test
./agents/"$name"/agent.sh "Confirm you are alive: state your role in one line."
```

Never copy an existing `session.jsonl` into a new agent unless the user
explicitly wants it to inherit that conversation.

## Give work

```bash
# Blocking: returns when the turn completes; output is printed.
./agents/researcher/agent.sh "Read X, summarize into outbox.md."

# Background: for long tasks. Watch the log; the lock dir shows liveness.
nohup ./agents/researcher/agent.sh "long task" > agents/researcher/run.log 2>&1 &

# Per-call overrides: cheaper model, higher turn budget, etc.
MODEL=gpt-5.5-mini MAX_TURNS=30 ./agents/researcher/agent.sh "task"
```

Exit code 75 means the agent is mid-run. Either wait for the lock, or queue a
message instead (next section) — queuing never blocks and never collides.

## Communicate through the session file

**Queue a task/message** (safe anytime, even mid-run — append only, built with
jq, exact record shape):

```bash
jq -nc \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg c "New instruction: also cover Y. Reply in outbox.md." \
  '{kind:"message", created_at:$t, role:"user", content:$c}' \
  >> agents/researcher/session.jsonl
```

Queued messages are processed on the agent's **next run** (its cron wake, or
any one-shot you fire later). To deliver now:

```bash
while [ -d agents/researcher/session.jsonl.lock ]; do sleep 5; done
./agents/researcher/agent.sh "Process any pending messages above."
```

**Read its state:**

```bash
# running or idle?
[ -d agents/researcher/session.jsonl.lock ] && echo running || echo idle

# last substantive reply
jq -r -s '[.[] | select(.role == "assistant" and (.content // "") != "")] | last.content' \
  agents/researcher/session.jsonl

# recent activity, one line per record
tail -n 8 agents/researcher/session.jsonl \
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

## Containers and Kubernetes

`ops/` in this repo has the full thin deployment (alpine + bash/curl/jq/rg/git,
multi-arch amd64+arm64): `ops/Dockerfile`, `ops/agent.yaml`,
`ops/build-push.sh`. Containers are **ephemeral by design**: the agent
self-seeds its session on first run and a pod replacement is a factory reset.
Identity is given the same way as everywhere else — by manipulating
`/work/session.jsonl` (`kubectl cp` a session in, or just message it).
Anything durable is the agent's own job: tell it to commit/push work products
to a git remote (`GIT_TOKEN` is wired in the manifest). Read
`ops/agent.yaml`'s header comment for the deploy/clone/operate commands. The
short version:

```bash
ops/build-push.sh                                   # build+push multi-arch image
kubectl apply -f ops/agent.yaml                     # deploy agent "agent-main"
sed 's/agent-main/agent-researcher/g' ops/agent.yaml | kubectl apply -f -   # clone
kubectl exec deploy/agent-main -- /work/agent.sh "task"                     # give work
kubectl exec deploy/agent-main -- tail -n 3 /work/session.jsonl             # read state
```

## Invariants (do not break these)

- Build every session line with `jq -nc` / `--rawfile`. Never hand-write JSON.
- Foreign sessions: **append only**. Never edit or delete existing lines of
  another agent's session — assistant `tool_calls` lines and their `tool`
  results are linked by id, and breaking a pair makes the API reject the whole
  session.
- One run per session; respect exit 75 instead of deleting a live lock. A lock
  whose owner pid is dead is taken over automatically — don't clean it by hand.
- A new agent needs its own folder and its own freshly authored session.
- Keep subagent prompts narrow: one role, one deliverable convention, "reply
  idle when nothing pending" — that is what makes cron wakes cheap.
