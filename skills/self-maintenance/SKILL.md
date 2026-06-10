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
means "fix or shrink the session file". Sessions are named
`session-<name>-<id>.jsonl` (legacy `session.jsonl` is honored too), so
resolve the file once and reuse it — and **never run repairs while that agent
is running**:

```bash
s=(session*.jsonl)   # the agent's single session file, any naming era
[ -d "${s[0]}.lock" ] && { echo "agent is running; do not touch"; exit 0; }
```

A folder with **several** `session-*.jsonl` files is itself a fault — the
agent refuses to run (exit 78). Keep the real one (usually the largest or
newest), move the others out of the folder, and rerun the checkup.

## Checkup (run this first)

```bash
wc -c "${s[0]}"                                       # > ~400000 bytes: compact soon
jq -es 'length' "${s[0]}" >/dev/null 2>&1 && echo OK || echo CORRUPT
ls "${s[0]}".bak.* 2>/dev/null | wc -l                # compaction backups piling up?
ls .cmd-output.* .cmd-status.* .llm-payload.* .llm-response.* 2>/dev/null # crash droppings?
```

If the session is OK but large, just call your `compact_session` tool (or, for
another agent, wake it with: "your session is large, compact it now").

## Repair a corrupt session

A crash mid-append leaves a torn last line. The replay tolerates this (it
silently skips unparseable lines), but a skipped line can orphan a tool-call
pair, and the API rejects the whole session when pairs don't match. Keep
evidence, drop unparseable lines, then fix tool-call pairing:

```bash
cp -- "${s[0]}" "${s[0]}.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
jq -cR 'fromjson?' "${s[0]}" > .repair && mv .repair "${s[0]}"
```

The API rejects a session whose assistant `tool_calls` and `tool` results do
not pair up, so after dropping lines, check both directions:

```bash
# tool calls that lost their result -> answer each one synthetically
jq -r -s '([.[] | select(.role=="assistant") | .tool_calls[]?.id]
           - [.[] | select(.role=="tool") | .tool_call_id])[]' "${s[0]}" \
| while IFS= read -r id; do
    jq -nc --arg id "$id" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:"message", created_at:$t, role:"tool", tool_call_id:$id,
        content:"{\"error\":\"tool result lost in crash repair\"}"}' >> "${s[0]}"
  done

# tool results that lost their call -> remove them
jq -c -s '[.[] | select(.role=="assistant") | .tool_calls[]?.id] as $asked
  | .[] | select(.role != "tool" or ([.tool_call_id] | inside($asked)))' \
  "${s[0]}" > .repair && mv .repair "${s[0]}"
```

Verify, then delete the `.corrupt.*` evidence file once a real run succeeds:

```bash
jq -es 'length' "${s[0]}" >/dev/null && echo repaired
```

## Routine cleanup (only when idle)

```bash
# keep the 3 newest compaction backups, drop the rest
ls -t "${s[0]}".bak.* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f -- "$f"; done

# crash droppings from interrupted runs
rm -f .cmd-output.* .cmd-status.* .llm-payload.* .llm-response.* .session-compact.*

# a stale lock from a dead pid is taken over automatically on the next run —
# do NOT delete lock directories by hand.
```

## Make it periodic

Pair with skills/cron for a standing checkup, e.g. weekly per agent:

```cron
10 6 * * 1 cd /abs/path/agents/researcher && ./agent.sh "Weekly checkup: run the self-maintenance skill checkup and cleanup on yourself; repair only if corrupt. Reply with one status line." >> cron.log 2>&1 # spirit-agent:researcher-checkup
```
