# Session editor UI

A tiny browser UI for viewing and editing the agent's session file as a single
conversation thread — click a message to expand it, ✎ to edit it in place, and
append new ones from a chat-style composer. It edits the same file `agent.sh`
replays verbatim to the model, so the editor *is* how you shape an agent's
identity and queue its work.

Zero dependencies beyond Node's standard library — no build step, no `npm install`.

## Run

```bash
./ui.sh --session /path/to/agent/session.jsonl   # point at an agent's session
./ui.sh --port 9000
./ui.sh --no-open                       # don't auto-open a browser
```

`ui.sh` is a thin launcher; `node server.js` with the same flags works
identically. `SESSION_FILE=...` is honored too (matching `agent.sh`). Without
`--session`/`SESSION_FILE` the server discovers the agent session in this
folder's parent the same way `agent.sh` does: a legacy `session.jsonl`, else
the folder's single `session-*.jsonl`. If the requested port is busy, the
server walks up one port at a time until it finds a free one — so several
agent UIs can all be launched with the same `--port` and they spread out
automatically.

## What it does

- **Conversation view.** One scrolling column, like a chat transcript. System /
  user / assistant messages are top-level; each `tool` result is nested under the
  assistant `tool_calls` that produced it (matched by `tool_call_id`). Color-coded
  by role.
- **Collapsed by default.** Every card is a one-line summary (for tool calls,
  the command itself rather than its JSON wrapper). Click a card to expand it,
  click again to collapse; the header's **Expand / Collapse** button toggles the
  whole thread, and very long expanded payloads still clamp behind "Show more".
- **Formatted JSON.** Expanded tool-call arguments and JSON tool results render
  one block per key — string values shown raw, with real newlines instead of
  `\n` escapes — and nested values pretty-printed with light syntax color.
- **Edit in place.** The ✎ button on a card opens an inline editor for its role,
  `content`, `created_at`, the `ephemeral` flag (system), `tool_call_id` (tool
  results), or — for assistant messages — each tool call's name / id /
  `arguments` (with a **Format** button to pretty-print them). A **Raw JSON**
  toggle edits the whole record and preserves any custom fields the form doesn't
  surface. Escape or **Done** closes.
- **Composer.** Type at the bottom and hit **Enter** — the message is appended
  *and saved* in one go, so a waiting `agent.sh` picks it up and the session just
  continues. Shift+Enter inserts a newline; a role picker covers system/assistant
  appends.
- **Live refresh.** While you have no unsaved edits, the UI polls the file and
  shows messages a running agent appends — you watch the session continue.
- **Insert / remove / reorder.** The inline editor has Up / Down / Delete and
  "+ Insert below"; ⌘/Ctrl-S saves pending edits.
- **Save = whole file.** Saving rewrites the session as one compact JSON object
  per line. Every save first copies the current file to
  `<session>.bak.<UTC stamp>` (same convention as `compact_session`), and the
  write is atomic (temp file + rename).

## Safety

- If a live agent run holds the session lock, saving is refused (HTTP 409); the
  UI offers to force, since editing mid-turn would interleave with the run.
- Lines that don't parse as JSON are reported in a banner and would be dropped on
  save — fix or remove them first.
- Binds to `127.0.0.1` only.
