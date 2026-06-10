---
name: cron
description: >
  Schedule recurring or one-time work with cron — including waking yourself or
  other agents on a schedule. Use whenever the user says "every day/hour",
  "periodically", "keep checking", "remind me", "schedule", "at 9am", or wants
  an agent to have a standing task that survives between conversations. Covers
  reading/adding/removing crontab entries safely, the agent wake pattern,
  self-removing one-time jobs, and cron's environment gotchas.
requires: crontab
---

# Cron

Schedule work on the host with `crontab`. In a container there is usually no
cron daemon — use the deployment's `AGENT_INTERVAL` env instead (see
skills/agent-workshop); this skill is for hosts (macOS, Linux servers).

## Rules

- **Tag every entry you create** with a trailing marker comment
  `# bash-agent:<job-name>` so it can be listed and removed exactly, without
  touching entries owned by the user or other tools.
- Never replace the whole crontab blind: always start from `crontab -l` and
  filter, so existing entries survive.
- Cron runs with a minimal environment: no PATH from your shell, no exported
  keys. Use absolute paths and `cd` into the agent folder; the API key must be
  reachable (`LLM_API_KEY` in that agent's `agent.env`, or set it inline in
  the cron line).

## Recipes

```bash
# List everything / only your entries
crontab -l 2>/dev/null
crontab -l 2>/dev/null | grep -F '# bash-agent:'

# Add an entry (append, keep the rest)
( crontab -l 2>/dev/null
  printf '%s\n' '*/15 * * * * cd /abs/path/agents/researcher && ./agent.sh "Wake: continue your standing task. If nothing pending, reply exactly: idle." >> cron.log 2>&1 # bash-agent:researcher-wake'
) | crontab -

# Remove one of your entries by its marker
crontab -l 2>/dev/null | grep -vF '# bash-agent:researcher-wake' | crontab -

# One-time job: the line removes itself after running
( crontab -l 2>/dev/null
  printf '%s\n' '30 9 14 6 * cd /abs/path && ./agent.sh "send the report" >> cron.log 2>&1; crontab -l | grep -vF "# bash-agent:once-report" | crontab - # bash-agent:once-report'
) | crontab -
```

## Agent wake pattern

- A wake is just a one-shot run: `cd <agent folder> && ./agent.sh "Wake: ..."`.
- If a wake fires while the agent is already running, it exits 75 (session
  busy) — harmless; the next wake catches up. Queued messages in the session
  are processed on whichever run comes next.
- Stagger fleets so they do not hit the API at the same instant: `*/15` for
  one agent, `2-59/15` for the next, `4-59/15` after that.
- Keep wake prompts cheap: the agent's system prompt should say to reply
  exactly `idle` when nothing is pending, so an idle wake costs one model call.

## Verify and debug

```bash
crontab -l | tail -n 5            # entry is really there
tail -n 40 /abs/path/cron.log     # what the last wakes did
```

- macOS: cron may need Full Disk Access (System Settings > Privacy) to read
  the agent folder; if wakes silently do nothing, check `cron.log` exists at
  all.
- Minute granularity is the floor. For "every 30 seconds" use the container
  loop mode instead.
