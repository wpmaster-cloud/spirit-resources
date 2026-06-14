---
name: google
requires: curl, jq
description: >
  Send and read Gmail, manage Google Drive, and read/create Google Calendar events
  from the agent over the Google REST APIs using nothing but curl + jq — no
  libraries, no installation. Authenticates with a Google OAuth refresh token
  (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / GOOGLE_REFRESH_TOKEN), minting
  short-lived access tokens automatically. Use whenever the user wants the agent
  to send an email from their Gmail, read or search their Gmail, email a file as
  an attachment, upload a file to Google Drive, share a Drive link, list/search
  Drive, download a Drive file/Doc, check their calendar / what's coming up, or
  create/schedule a calendar event. This is the Gmail-over-OAuth path; for a
  non-Gmail mailbox or plain app-password IMAP/SMTP, use the `email` skill
  instead — see "Which email skill?" below. Trigger
  phrases: "gmail", "google drive", "drive", "google calendar", "my calendar",
  "schedule a meeting", "add an event", "what's on my calendar", "send from my
  gmail", "read my gmail", "search my email", "upload to drive", "share a drive
  link", "download from drive", "google docs", "put this on my google drive".
---

# Google: Gmail + Drive + Calendar (curl-only, OAuth)

Two-way Gmail, Google Drive, and Google Calendar for the agent over Google's REST
APIs. A single OAuth **refresh token** (minted once) is exchanged for short-lived
access tokens on every call by `_common.sh` — so there is nothing to install and
nothing to re-authorize day to day.

> ## Which email skill? (google vs. email)
> Two skills can send/read mail and both match "send an email" — pick **one** by
> what's configured in the environment, don't try both:
>
> | Configured env var | Use this skill | Why |
> |---|---|---|
> | `GOOGLE_REFRESH_TOKEN` set | **`google`** (this one) | Gmail over OAuth, no app password |
> | only `EMAIL_PASSWORD` / `EMAIL_ADDRESS` set | **`email`** | generic IMAP/SMTP, any host |
> | both set | **`google`** | OAuth is the more capable Gmail path |
>
> Check first: `env | grep -E 'GOOGLE_REFRESH_TOKEN|EMAIL_PASSWORD'`. If neither
> is set, mail isn't configured — say so instead of guessing. The `email` skill
> is the right choice for iCloud/Outlook/Fastmail/any non-Gmail box.

```
skills/google/
├── SKILL.md
├── config.env.example          # template for credentials
├── scripts/
│   ├── _common.sh              # shared: creds + access-token minting/cache + curl wrapper
│   ├── g_setup.sh              # verify the token; print account email + Drive quota
│   ├── gmail_send.sh           # send mail (text/HTML, cc/bcc, attachments)
│   ├── gmail_read.sh           # list / search / read messages
│   ├── drive_upload.sh         # upload a local file (optionally share by link)
│   ├── drive_list.sh           # list / search Drive
│   ├── drive_download.sh       # download a file (or export a Google Doc)
│   ├── gcal_list.sh            # list upcoming calendar events
│   └── gcal_add.sh             # create a calendar event
└── references/
    └── google-api.md           # minting the refresh token, scopes, more endpoints, errors
```

`run_command`'s working directory is the **workspace root**, so invoke scripts as
`bash skills/google/scripts/<name>.sh …`.

## 1. One-time setup

**a. Get OAuth credentials + a refresh token.** This is the only fiddly part and
it's done once. Create an OAuth client, enable the Gmail + Drive APIs, and mint a
refresh token carrying the scopes you need — full step-by-step (incl. the OAuth
Playground shortcut) is in `references/google-api.md`. You end up with three
values: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`.

**b. Store credentials.** Two options (pick one):

- **Env vars (recommended, secret-safe).** Put these in the environment the agent
  process starts with — the shell/cron line that launches `agent.sh`, the pod's
  Secret-backed `env:`, or (in the admin-ui) the agent's **Profile** box, which
  injects them into that agent's runs (the runtime does **not** read a `.env`
  file):
  ```
  GOOGLE_CLIENT_ID=....apps.googleusercontent.com
  GOOGLE_CLIENT_SECRET=....
  GOOGLE_REFRESH_TOKEN=1//....
  ```
  `run_command` children inherit the agent's environment, so the **token never
  appears in the transcript**.

- **Config file.** `cp skills/google/config.env.example google/config.env`, fill
  it in, and make sure `google/config.env` is git-ignored in the agent's folder.
  The scripts auto-source it. Env vars win when both are set.

**c. Verify.**
```bash
bash skills/google/scripts/g_setup.sh
```
It mints an access token and calls the Gmail profile + Drive "about" endpoints,
printing your account email and storage — confirming the token works and which
scopes it carries before you rely on it.

## 2. Gmail — sending

```bash
# plain text
bash skills/google/scripts/gmail_send.sh --to boss@acme.com \
  --subject "Weekly report" --body "Done — see attached."

# cc + HTML + attachments (repeat --to / --attach)
bash skills/google/scripts/gmail_send.sh --to a@x.com --cc lead@x.com \
  --subject "Q2 numbers" --html-file out/report.html \
  --attach reports/q2.pdf --attach reports/q2.xlsx

# long body via stdin
echo "$BODY" | bash skills/google/scripts/gmail_send.sh --to me@x.com --subject hi --stdin
```
Prints `sent ok: id=…`. Needs the `gmail.send` scope.

## 3. Gmail — reading & searching

```bash
# 10 most recent in the inbox (does NOT mark them read)
bash skills/google/scripts/gmail_read.sh

# any Gmail search query (same syntax as the Gmail search box)
bash skills/google/scripts/gmail_read.sh --query "is:unread" --max 20
bash skills/google/scripts/gmail_read.sh --query "from:boss@acme.com newer_than:2d"

# one message with its decoded text body; mark unread ones read
bash skills/google/scripts/gmail_read.sh --id 18fab... --full
bash skills/google/scripts/gmail_read.sh --query "is:unread" --mark-read
```
Output is one line per message: `<id>  | <date> | <From> | <Subject>`; `--full`
appends the text/plain body. Needs `gmail.readonly` (or `gmail.modify` for
`--mark-read`).

## 4. Drive — upload, list, download

```bash
# upload (name defaults to the filename); optionally into a folder, or link-shared
bash skills/google/scripts/drive_upload.sh out/report.pdf --name "Q2 Report.pdf"
bash skills/google/scripts/drive_upload.sh report.pdf --folder <FOLDER_ID> --anyone-reader

# list / search (Drive query syntax — see references/google-api.md)
bash skills/google/scripts/drive_list.sh
bash skills/google/scripts/drive_list.sh --query "name contains 'report'" --max 50

# download a binary file, or export a native Google Doc
bash skills/google/scripts/drive_download.sh <FILE_ID> -o local.pdf
bash skills/google/scripts/drive_download.sh <DOC_ID> --export application/pdf -o doc.pdf
```
Upload prints `uploaded ok: id=…` and a `webViewLink`. Needs a `drive` or
`drive.file` scope (downloading files this app didn't create needs `drive`).

## 5. Calendar — read & create events

```bash
# next 10 upcoming events on the primary calendar
bash skills/google/scripts/gcal_list.sh
bash skills/google/scripts/gcal_list.sh --max 25 --query "standup"

# a timed event (give a timezone, or it defaults to $TZ / UTC)
bash skills/google/scripts/gcal_add.sh --summary "Sync" \
  --start 2026-06-15T14:00:00 --end 2026-06-15T15:00:00 --timezone Asia/Jerusalem \
  --location "Room 1" --attendee a@x.com --attendee b@x.com

# an all-day event (end date is exclusive, Google's convention)
bash skills/google/scripts/gcal_add.sh --summary "Trip" \
  --start 2026-07-01 --end 2026-07-05 --all-day
```
`gcal_list.sh` prints `<start> | <summary> [@ location] (<id>)`; `gcal_add.sh`
prints the new event id + link. Listing needs `calendar.readonly`, creating needs
`calendar` or `calendar.events`.

## 6. A Gmail-driven assistant (the cron wake pattern)

To make the agent watch Gmail and act on incoming mail on a schedule, give it a
standing wake (the **cron** skill on a host, or the wake-loop `command:` in
`ops/agent.yaml` for a container). Every firing is a one-shot run against the
agent's **one session**, so context accumulates and `compact_session` keeps it
bounded — same pattern as the telegram/whatsapp skills.

```cron
*/5 * * * * cd /abs/path/agents/gmail-bot && ./agent.sh "Wake: check Gmail by running bash skills/google/scripts/gmail_read.sh --query 'is:unread' --full. For each message that needs action, do it (and reply with gmail_send.sh if asked), then mark it read. If nothing is unread, reply exactly: idle." >> cron.log 2>&1 # spirit-agent:gmail-poll
```

**Other uses of the same building blocks:**
- *Notifications* — call `gmail_send.sh` at the end of a long task to email a report.
- *Hand-off to Drive* — generate a file (e.g. via the `create-pdf-pptx-xlsx-docx`
  skill), `drive_upload.sh --anyone-reader` it, then send the link by Gmail,
  Telegram, or WhatsApp.

## Gotchas (read before debugging)

- **`invalid_grant` on setup** ⇒ refresh token revoked/expired or client id/secret
  mismatch. Unverified ("Testing") OAuth apps expire refresh tokens after **7
  days** — publish the app to stop that. Re-mint per `references/google-api.md`.
- **403 `insufficientPermissions` / scope errors** ⇒ the refresh token lacks the
  scope for that call (e.g. `--mark-read` needs `gmail.modify`; downloading
  someone else's file needs `drive`). Re-mint with the scope added — adding a
  scope requires a new refresh token.
- **Access token caching** — tokens live in `google/.access_token` and auto-refresh
  ~60s before expiry; delete that file to force a fresh mint.
- **Native Google Docs won't download with `alt=media`** (403) — use `--export`
  with a target MIME (`application/pdf`, `.docx`, `.xlsx` — see the reference).
- **Large uploads** — `drive_upload.sh` uses multipart and base64-buffers the file
  in memory; for files over ~5–10 MB prefer resumable upload (reference) or accept
  the memory cost.
- **This sends as the real account** — Gmail has daily send caps (~500/day free)
  and spam policies; don't bulk-send.
- **Works from a deployed pod unchanged** — every call is HTTPS on 443, which the
  stock NetworkPolicy in `ops/agent.yaml` already allows.

For minting the refresh token, the scope table, Gmail/Drive query syntax, thread
& attachment endpoints, folder creation, shared drives, and error codes, read
`references/google-api.md`.
