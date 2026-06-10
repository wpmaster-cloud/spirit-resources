---
name: telegram
requires: curl
description: >
  Send and receive Telegram messages from the agent using nothing but curl — no
  libraries, no installation. Use whenever the user wants the agent to text/message
  them on Telegram, send a notification or alert to a phone, "ping me when done",
  read incoming Telegram messages, poll for replies, or run a two-way Telegram chat
  / bot / assistant. Covers sendMessage (outgoing) and getUpdates (incoming, with
  offset memory so each message is read once), plus a cron wake pattern that turns
  the agent into a Telegram chatbot. Trigger phrases:
  "telegram", "text me", "message me on telegram", "telegram bot", "notify me",
  "send me an alert", "read my telegram", "reply to telegram", "chat over telegram".
---

# Telegram (curl-only)

Two-way Telegram messaging for the agent. Everything is plain HTTPS against the
Telegram Bot API via `curl` — there is nothing to install. Three bundled scripts
wrap the two calls you actually need (`sendMessage`, `getUpdates`) and handle the
fiddly parts (URL-encoding, offset memory, webhook conflicts).

```
skills/telegram/
├── SKILL.md
├── config.env.example          # template for credentials
├── scripts/
│   ├── _common.sh              # shared: credential + state resolution, curl wrapper
│   ├── tg_setup.sh             # verify token, clear webhook, discover your chat id
│   ├── tg_send.sh              # send a message
│   └── tg_read.sh              # read NEW messages (remembers what it already saw)
└── references/
    └── bot-api.md              # extended reference: more methods, parse modes, errors
```

All commands below assume the agent's `run_command`, whose working directory is the
**workspace root**, so paths are written relative to it (`skills/telegram/...`).

## 1. One-time setup

**a. Create a bot and get a token.** In Telegram, message **@BotFather** → `/newbot`
→ follow prompts. It returns a token like `123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.

**b. Store credentials.** Two options (pick one):

- **Env vars (recommended, secret-safe).** Put these in the environment the
  agent process starts with — the shell/cron line that launches `agent.sh`, or
  the pod's Secret-backed `env:` for a containerized agent (the runtime does
  **not** read a `.env` file):
  ```
  TELEGRAM_BOT_TOKEN=123456789:AAE...
  TELEGRAM_CHAT_ID=               # fill in after step c
  ```
  `run_command` children inherit the agent's environment, so the **token never
  appears in the transcript**.

- **Config file.** Copy the template and fill it in:
  ```bash
  cp skills/telegram/config.env.example telegram/config.env
  # then edit telegram/config.env
  ```
  The scripts auto-source `telegram/config.env`. Make sure it's git-ignored in
  the agent's folder so the token isn't committed.

Env vars win over the config file when both are present.

**c. Verify + find your chat id.** First send your bot any message in Telegram
(say "hi"). Then:
```bash
bash skills/telegram/scripts/tg_setup.sh
```
This confirms the token (`getMe`), clears any webhook (needed for polling), and
prints the chat ids that have messaged the bot. Put the right `chat_id` into your
credentials (env var `TELEGRAM_CHAT_ID` or `telegram/config.env`).

## 2. Sending a message

```bash
# plain text (safest — no escaping needed)
bash skills/telegram/scripts/tg_send.sh "Build finished ✅ — 0 failures."

# to a specific chat, as a reply, silent
bash skills/telegram/scripts/tg_send.sh --chat 12345 --reply-to 678 --silent "ack"

# long body via stdin
echo "$BODY" | bash skills/telegram/scripts/tg_send.sh --stdin

# formatted (you MUST escape — see references/bot-api.md)
bash skills/telegram/scripts/tg_send.sh --parse HTML "<b>Done</b> in <code>3s</code>"
```
On success it prints `sent ok: message_id=… chat=…`; on failure it prints the
Telegram error and exits non-zero. Defaults to **plain text** — only pass
`--parse MarkdownV2|HTML` if you have escaped the text per Telegram's rules.

## 3. Reading incoming messages

```bash
# new messages since the last read (returns immediately)
bash skills/telegram/scripts/tg_read.sh

# wait up to 25s for something to arrive (long poll)
bash skills/telegram/scripts/tg_read.sh --timeout 25

# only one chat / raw JSON / look without consuming / start over
bash skills/telegram/scripts/tg_read.sh --chat 12345
bash skills/telegram/scripts/tg_read.sh --raw
bash skills/telegram/scripts/tg_read.sh --peek
bash skills/telegram/scripts/tg_read.sh --reset
```
Output is one line per message:
```
<update_id>  [<chat_id>]  <name> @username: <text>   [photo]/[document: …] for non-text
```
(`--limit <n>` caps how many updates one call returns; default 100.)

**Offset memory:** the script stores the last seen `update_id + 1` in
`telegram/offset` and passes it as the next `getUpdates` offset. This both filters
out already-seen messages **and** tells Telegram to drop them server-side, so each
message is returned exactly once. Reading **consumes** — use `--peek` to look
without advancing, `--reset` to forget and re-read the backlog.

## 4. A two-way conversation (the cron wake pattern)

To make the agent an actual Telegram assistant that reads incoming messages and
replies on a schedule, give it a standing wake (see the **cron** skill on a host,
or the wake-loop `command:` in `ops/agent.yaml` for a container). Every firing is
a one-shot run against the agent's **one session**, so the conversation
accumulates naturally and `compact_session` keeps it bounded.

```cron
* * * * * cd /abs/path/agents/telegram-bot && ./agent.sh "Wake: check Telegram by running bash skills/telegram/scripts/tg_read.sh. For each new message directed at you, write a helpful reply and send it with bash skills/telegram/scripts/tg_send.sh --chat <CHAT_ID> --reply-to <MESSAGE_ID> '...'. If there are no new messages, reply exactly: idle." >> cron.log 2>&1 # spirit-agent:telegram-poll
```

Mechanics that make this work:
- Each firing appends the wake text as a user message and runs one turn loop;
  a wake that lands mid-run exits 75 harmlessly (the next one catches up).
- Bake the standing instructions (role, reply style, "never send unprompted
  messages") into the agent's **system prompt** so the per-wake message stays
  short — see skills/agent-workshop for authoring a session.
- A typical firing is ~3 model calls: read → (reply if needed) → finish.

For snappier (sub-minute) responsiveness, have a single firing long-poll a few
times in a row (`tg_read.sh --timeout 25`) within one wake. The 1-minute cron is
the simplest, most robust default.

**Other uses of the same building blocks:**
- *Notifications / alerts* — call `tg_send.sh` at the end of any long task to
  ping the user when it finishes or fails.
- *Ad-hoc* — when the user says "text me when X", just call `tg_send.sh`
  directly; no standing wake needed.

## Gotchas (read before debugging)

- **HTTP 409 on getUpdates** ⇒ a webhook is set; `getUpdates` and webhooks are
  mutually exclusive. Run `tg_setup.sh` (it calls `deleteWebhook`).
- **HTTP 400 on send with `--parse`** ⇒ unescaped special characters. MarkdownV2
  requires escaping `_ * [ ] ( ) ~ \` > # + - = | { } . !` — see
  `references/bot-api.md`. When in doubt, send plain text (no `--parse`).
- **4096-char limit** per message; split longer text into chunks.
- **Reading consumes** — once `tg_read.sh` advances the offset, those updates are
  gone from `getUpdates`. The text is still in your command output/transcript, but
  re-running won't return them. Use `--peek` if you only want to look.
- **Rate limits** — ~1 msg/sec per chat, ~30 msg/sec overall; bursts get HTTP 429
  with `retry_after`. Don't loop-send without pacing.
- **No chat id yet** — the bot can't message a user who has never started a chat
  with it. The user must message the bot first (or join the group).

For more methods (`sendPhoto`, `sendDocument`, `sendChatAction`, keyboards), the
full update object, parse-mode escaping tables, and error codes, read
`references/bot-api.md`.
