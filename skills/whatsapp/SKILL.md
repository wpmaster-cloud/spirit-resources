---
name: whatsapp
requires: curl, jq
description: >
  Send and receive WhatsApp messages from the agent through green-api.com using
  nothing but curl + jq — no libraries, no installation. Use whenever the user
  wants the agent to message them (or anyone) on WhatsApp, send a notification
  or alert to a phone, "ping me when done", send a file/image/document to a
  WhatsApp chat or group, read incoming WhatsApp messages, poll for replies, or
  run a two-way WhatsApp chat / bot / assistant. Covers instance pairing (QR),
  sendMessage / sendFileByUrl (outgoing) and the receiveNotification /
  deleteNotification queue (incoming, each message delivered exactly once),
  plus a cron wake pattern that turns the agent into a WhatsApp chatbot.
  Trigger phrases: "whatsapp", "green api", "green-api", "message me on
  whatsapp", "whatsapp bot", "send to my whatsapp", "whatsapp group",
  "read my whatsapp", "reply on whatsapp".
---

# WhatsApp via Green API (curl-only)

Two-way WhatsApp messaging for the agent. [Green API](https://green-api.com)
puts a plain HTTPS API in front of a real WhatsApp account (paired like
WhatsApp Web), so everything here is `curl` + `jq` — nothing to install. Three
bundled scripts wrap the calls you actually need and handle the fiddly parts
(JSON escaping, the consume-on-delete queue, chatId normalization).

```
skills/whatsapp/
├── SKILL.md
├── config.env.example          # template for credentials
├── scripts/
│   ├── _common.sh              # shared: credential resolution, curl wrapper, chatId helper
│   ├── wa_setup.sh             # check auth state, save pairing QR, verify/fix settings
│   ├── wa_send.sh              # send a text message or a file (by URL)
│   └── wa_read.sh              # read NEW notifications (consume-on-delete queue)
└── references/
    └── green-api.md            # extended reference: more methods, payload shapes, errors
```

All commands below assume the agent's `run_command`, whose working directory is
the **workspace root**, so paths are written relative to it (`skills/whatsapp/...`).

## 1. One-time setup

**a. Create a Green API instance.** At <https://console.green-api.com>: sign up
→ create an instance (the free **Developer** plan gives one instance with
restrictions — notably only ~3 allowed chats and no group creation; paid plans
lift this). The console shows three values you need: **idInstance**,
**apiTokenInstance**, and the instance's **apiUrl**.

**b. Store credentials.** Two options (pick one):

- **Env vars (recommended, secret-safe).** Put these in the environment the
  agent process starts with — the shell/cron line that launches `agent.sh`, or
  the pod's Secret-backed `env:` for a containerized agent (the runtime does
  **not** read a `.env` file):
  ```
  GREENAPI_ID_INSTANCE=1101000001
  GREENAPI_API_TOKEN=d75b3a66374942c5b3c019c698abc2067e151558acbd412345
  GREENAPI_API_URL=https://7103.api.greenapi.com   # exactly as the console shows
  WHATSAPP_DEFAULT_CHAT_ID=                        # optional default recipient
  ```
  `run_command` children inherit the agent's environment, so the **token never
  appears in the transcript**.

- **Config file.** Copy the template and fill it in:
  ```bash
  cp skills/whatsapp/config.env.example whatsapp/config.env
  # then edit whatsapp/config.env
  ```
  The scripts auto-source `whatsapp/config.env`. Make sure it's git-ignored in
  the agent's folder so the token isn't committed.

Env vars win over the config file when both are present.

**c. Pair the WhatsApp account + verify settings.**
```bash
bash skills/whatsapp/scripts/wa_setup.sh
```
- If the state is `notAuthorized` it saves a pairing QR to `whatsapp/qr.png` —
  scan it from the phone (**WhatsApp → Settings → Linked Devices → Link a
  Device**). The QR rotates every ~20s; re-run with `--qr` for a fresh one, or
  scan the live one in the console. Re-run until the state is `authorized`.
- It then checks the two settings polling depends on: `webhookUrl` must be
  **empty** and `incomingWebhook` must be `yes`. If they're wrong, re-run with
  `--fix-settings` (this **reboots the instance**; settings apply within ~5 min).
- `wa_setup.sh --check 79001234567` tells you whether a number is on WhatsApp.

**chatId formats** (used everywhere): a person is `<countrycode+number>@c.us`
(e.g. `79001234567@c.us` — international format, digits only, no `+`); a group
is `<id>@g.us`. `wa_send.sh` accepts a bare phone number and normalizes it.

## 2. Sending

```bash
# plain text to the default chat ($WHATSAPP_DEFAULT_CHAT_ID)
bash skills/whatsapp/scripts/wa_send.sh "Build finished ✅ — 0 failures."

# to a specific person / group, quoting a message
bash skills/whatsapp/scripts/wa_send.sh --chat 79001234567 "hello"
bash skills/whatsapp/scripts/wa_send.sh --chat 120363043968066463@g.us --reply-to 3EB0C767D097B7C7C030 "ack"

# long body via stdin (up to 20000 chars)
echo "$BODY" | bash skills/whatsapp/scripts/wa_send.sh --stdin

# a file by URL (≤100 MB; image/video/document/audio — type inferred from extension)
bash skills/whatsapp/scripts/wa_send.sh --file-url https://example.com/report.pdf --name report.pdf --caption "Q2 report"
```
On success it prints `sent ok: idMessage=… chat=…`; on failure it prints the
API error and exits non-zero. WhatsApp formatting works in plain text:
`*bold*`, `_italic_`, `~strike~`, ```` ```mono ```` — no escaping needed.

## 3. Reading incoming messages

Green API queues every event server-side for 24h; you **pull one notification
at a time and delete it to get the next** (FIFO). `wa_read.sh` does the loop:

```bash
# drain everything new (returns quickly when the queue is empty)
bash skills/whatsapp/scripts/wa_read.sh

# wait up to 20s for something to arrive (long poll, 5-60s)
bash skills/whatsapp/scripts/wa_read.sh --timeout 20

# at most 5 / raw JSON / look at the oldest without consuming
bash skills/whatsapp/scripts/wa_read.sh --max 5
bash skills/whatsapp/scripts/wa_read.sh --raw
bash skills/whatsapp/scripts/wa_read.sh --peek
```
Output is one line per notification:
```
in   [79001234567@c.us]  Tomer: can you check the server?  (idMessage=ABC123…)
out  [79001234567@c.us]  on it  (idMessage=DEF456…)
--   [79001234567@c.us] status delivered idMessage=DEF456…
```
Media messages print as `[imageMessage: <downloadUrl>] <caption>` — fetch the
URL with curl if you need the file (links live ~24h, longer on paid plans).

**Reading consumes:** after deletion a notification is gone from the server
(the text is still in your transcript). `--peek` looks without consuming, but
since the queue is FIFO it always shows the same oldest item. Note the queue
also receives *your own* outgoing sends (`outgoingAPIMessageReceived`) and
delivery statuses — `wa_read.sh` labels them `out` / `--` so you can ignore them.

## 4. A two-way conversation (the cron wake pattern)

To make the agent an actual WhatsApp assistant that reads incoming messages and
replies on a schedule, give it a standing wake (see the **cron** skill on a
host, or the wake-loop `command:` in `ops/agent.yaml` for a container). Every
firing is a one-shot run against the agent's **one session**, so the
conversation accumulates naturally and `compact_session` keeps it bounded.

```cron
* * * * * cd /abs/path/agents/whatsapp-bot && ./agent.sh "Wake: check WhatsApp by running bash skills/whatsapp/scripts/wa_read.sh. For each new incoming message directed at you, write a helpful reply and send it with bash skills/whatsapp/scripts/wa_send.sh --chat <CHAT_ID> '...'. Ignore 'out' and '--' lines (your own sends and statuses). If there are no new messages, reply exactly: idle." >> cron.log 2>&1 # spirit-agent:whatsapp-poll
```

Mechanics that make this work:
- Each firing appends the wake text as a user message and runs one turn loop;
  a wake that lands mid-run exits 75 harmlessly (the next one catches up).
- Bake the standing instructions (role, reply style, "never message anyone
  unprompted") into the agent's **system prompt** so the per-wake message stays
  short — see skills/agent-workshop for authoring a session.
- A typical firing is ~3 model calls: read → (reply if needed) → finish.

For snappier responses, have a single firing long-poll a few times in a row
(`wa_read.sh --timeout 25`) within one wake. The 1-minute cron is the simplest,
most robust default.

**Other uses of the same building blocks:**
- *Notifications / alerts* — call `wa_send.sh` at the end of any long task to
  ping the user when it finishes or fails.
- *Ad-hoc* — when the user says "whatsapp me when X", just call `wa_send.sh`
  directly; no standing wake needed.

## Gotchas (read before debugging)

- **State must be `authorized`.** Every send fails while the instance is
  `notAuthorized` / `starting` / `sleepMode` — run `wa_setup.sh` first and pair
  via QR. `blocked` / `yellowCard` mean WhatsApp restricted the account.
- **400 on receiveNotification** ⇒ a `webhookUrl` is configured; webhooks and
  polling are mutually exclusive. `wa_setup.sh --fix-settings` clears it.
- **No incoming messages ever appear** ⇒ `incomingWebhook` is `no` in settings
  (same fix). Also remember settings changes take ~5 min and reboot the instance.
- **This is a real WhatsApp account, not a bot platform.** WhatsApp bans
  numbers for spam: message only people who expect it, pace bulk sends (a few
  seconds between messages, slower for cold contacts), and prefer replying over
  initiating. A ban shows up as `yellowCard`/`blocked` state.
- **Free Developer plan limits**: messages only to ~3 whitelisted chats; other
  recipients fail with a quota error. Check the console if sends mysteriously fail.
- **Don't send to a number without WhatsApp** — repeated sends to non-existent
  accounts hurt the account's standing; use `wa_setup.sh --check <number>` when unsure.
- **The queue mixes event types** — your own sends and statuses come back as
  notifications. Don't reply to `out` lines or you'll talk to yourself in a loop.
- **Phone offline**: the paired phone must be online-ish (like WhatsApp Web);
  long offline periods delay or drop delivery.

For more methods (`getChatHistory`, `lastIncomingMessages`, `sendPoll`,
`sendLocation`, `sendContact`, `downloadFile`, group management), full
notification payload shapes, instance states, and error codes, read
`references/green-api.md`.
