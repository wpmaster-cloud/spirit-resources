---
name: self-maintenance
description: >
  Health-check and repair this agent (or another agent in a fleet). Use when a
  session file fails to parse or the agent crashed mid-run, when the session
  has grown large, when backups or temp files pile up, for a periodic
  "checkup" wake, or whenever the user says the agent is broken, stuck,
  corrupt, too big, or needs cleaning. Covers: validating session.jsonl,
  repairing torn lines and broken tool-call pairs after a crash, pruning
  compaction backups, and removing crash droppings.
requires: jq
---

# Self-maintenance

The session file is the agent's only state, so "fix the agent" almost always
means "fix or shrink the session file". All recipes work on any agent's
folder, not just your own — but **never run repairs while that agent is
running**:

```bash
[ -d session.jsonl.lock ] && { echo "agent is running; do not touch"; exit 0; }
```

## Checkup (run this first)

```bash
wc -c session.jsonl                                       # > ~400000 bytes: compact soon
jq -es 'length' session.jsonl >/dev/null 2>&1 && echo OK || echo CORRUPT
ls session.jsonl.bak.* 2>/dev/null | wc -l                # compaction backups piling up?
ls .cmd-output.* .cmd-status.* .llm-response.* 2>/dev/null # crash droppings?
```

If the session is OK but large, just call your `compact_session` tool (or, for
another agent, wake it with: "your session is large, compact it now").

## Repair a corrupt session

A crash mid-append leaves a torn last line; the strict replay then refuses to
start. Keep evidence, drop unparseable lines, then fix tool-call pairing:

```bash
cp -- session.jsonl "session.jsonl.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
jq -cR 'fromjson?' session.jsonl > .repair && mv .repair session.jsonl
```

The API rejects a session whose assistant `tool_calls` and `tool` results do
not pair up, so after dropping lines, check both directions:

```bash
# tool calls that lost their result -> answer each one synthetically
jq -r -s '([.[] | select(.role=="assistant") | .tool_calls[]?.id]
           - [.[] | select(.role=="tool") | .tool_call_id])[]' session.jsonl \
| while IFS= read -r id; do
    jq -nc --arg id "$id" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:"message", created_at:$t, role:"tool", tool_call_id:$id,
        content:"{\"error\":\"tool result lost in crash repair\"}"}' >> session.jsonl
  done

# tool results that lost their call -> remove them
jq -c -s '[.[] | select(.role=="assistant") | .tool_calls[]?.id] as $asked
  | .[] | select(.role != "tool" or ([.tool_call_id] | inside($asked)))' \
  session.jsonl > .repair && mv .repair session.jsonl
```

Verify, then delete the `.corrupt.*` evidence file once a real run succeeds:

```bash
jq -es 'length' session.jsonl >/dev/null && echo repaired
```

## Routine cleanup (only when idle)

```bash
# keep the 3 newest compaction backups, drop the rest
ls -t session.jsonl.bak.* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f -- "$f"; done

# crash droppings from interrupted runs
rm -f .cmd-output.* .cmd-status.* .llm-response.* .session-compact.*

# a stale lock from a dead pid is taken over automatically on the next run —
# do NOT delete lock directories by hand.
```

## Make it periodic

Pair with skills/cron for a standing checkup, e.g. weekly per agent:

```cron
10 6 * * 1 cd /abs/path/agents/researcher && ./agent.sh "Weekly checkup: run the self-maintenance skill checkup and cleanup on yourself; repair only if corrupt. Reply with one status line." >> cron.log 2>&1 # bash-agent:researcher-checkup
```
