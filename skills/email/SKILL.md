---
name: email
requires: python3
description: >
  Send and read email from the agent over standard IMAP + SMTP — no third-party
  service, no API keys, just the Python standard library. Use whenever the user
  wants the agent to email someone, send a report/notification/attachment by email,
  read or search their inbox, check for new mail, reply to a message, or run an
  email-driven workflow. Works with Gmail, Outlook/Office365, iCloud, Yahoo,
  Fastmail, Zoho, and any IMAP/SMTP host — this is the generic app-password path.
  If the agent instead has Google OAuth creds (GOOGLE_REFRESH_TOKEN set), prefer
  the `google` skill for Gmail; see "Which email skill?" below. Trigger phrases:
  "email me", "send an email", "email this report", "check my inbox", "read my
  email", "any new email", "reply to that email", "mail the file to".
---

# Email (IMAP + SMTP, stdlib-only)

Two-way email with zero installs: the scripts use Python's built-in `smtplib`
(send), `imaplib` (read), and `email` (MIME) — nothing to `pip install`.

> ## Which email skill? (email vs. google)
> Two skills can send/read mail and both match "send an email" — pick **one** by
> what's configured in the environment, don't try both:
>
> | Configured env var | Use this skill | Why |
> |---|---|---|
> | `EMAIL_ADDRESS` / `EMAIL_PASSWORD` set | **`email`** (this one) | generic IMAP/SMTP app-password, any host |
> | `GOOGLE_REFRESH_TOKEN` set | **`google`** | Gmail over OAuth, no app password |
> | both set | **`google`** | OAuth is the more capable Gmail path |
>
> Check first: `env | grep -E 'GOOGLE_REFRESH_TOKEN|EMAIL_PASSWORD'`. This `email`
> skill is the right choice for iCloud/Outlook/Fastmail/Yahoo/Zoho or any
> non-Gmail box. If neither var is set, mail isn't configured — say so instead of
> guessing or filling in placeholder credentials.

```
skills/email/
├── SKILL.md
├── config.env.example
├── scripts/
│   ├── _email_common.py     # credential + provider-host resolution (shared)
│   ├── email_setup.py       # verify login, list mailboxes, provider guidance
│   ├── email_send.py        # send (text/HTML, cc/bcc, attachments)
│   └── email_read.py        # list / search / fetch messages, save attachments
└── references/
    └── providers.md         # host/port table, app-password setup, IMAP search, gotchas
```

`run_command`'s working directory is the **workspace root**, so invoke scripts as
`python3 skills/email/scripts/<name>.py …`.

## 1. One-time setup

**a. Use an app password, not your login password.** Modern providers block plain
password logins. Turn on 2-factor auth, then create an **app password** (Gmail:
Account → Security → App passwords; iCloud/Yahoo/Outlook similar — see
`references/providers.md`). Use that 16-ish-char value as `EMAIL_PASSWORD`.

**b. Store credentials.** Two options (pick one):

- **Env vars (recommended, secret-safe).** Put these in the environment the
  agent process starts with — the shell/cron line that launches `agent.sh`, or
  the pod's Secret-backed `env:` for a containerized agent (the runtime does
  **not** read a `.env` file):
  ```
  EMAIL_ADDRESS=you@gmail.com
  EMAIL_PASSWORD=your-app-password
  EMAIL_PROVIDER=gmail          # auto-fills IMAP/SMTP hosts; see providers.md
  ```
  `run_command` children inherit the agent's environment, so the **password
  never appears in the transcript**.

- **Config file.** `cp skills/email/config.env.example email/config.env`,
  fill it in, and make sure `email/config.env` is git-ignored in the agent's
  folder. The scripts auto-source it. Env vars win when both are set.

For a host not in the preset list, set `IMAP_HOST`/`IMAP_PORT`/`SMTP_HOST`/`SMTP_PORT`
explicitly instead of `EMAIL_PROVIDER`.

**c. Verify.**
```bash
python3 skills/email/scripts/email_setup.py
```
It logs into IMAP (and lists your mailboxes) and SMTP, confirming the credentials
and host settings before you rely on them.

## 2. Sending

```bash
# plain text
python3 skills/email/scripts/email_send.py --to boss@acme.com \
  --subject "Weekly report" --body "Done — see attached."

# multiple recipients, cc, attachment(s), HTML
python3 skills/email/scripts/email_send.py \
  --to a@x.com --to b@x.com --cc lead@x.com \
  --subject "Q2 numbers" --html-file out/report.html \
  --attach reports/q2.pdf --attach reports/q2.xlsx

# long body from stdin; preview without sending
echo "$BODY" | python3 skills/email/scripts/email_send.py --to me@x.com --subject hi --stdin
python3 skills/email/scripts/email_send.py --to me@x.com --subject test --body hi --dry-run
```
Key flags: `--to/--cc/--bcc` (repeatable or comma-separated), `--subject`,
`--body`/`--body-file`/`--stdin`, `--html`/`--html-file`, `--attach` (repeatable),
`--reply-to`, `--from-name`, `--save-sent` (best-effort append to the Sent mailbox —
SMTP sending does **not** populate Sent on its own), `--dry-run` (build + summarize,
don't send).

## 3. Reading & searching

```bash
# 10 most recent in the inbox (headers only; does NOT mark them read)
python3 skills/email/scripts/email_read.py

# only unread, show full body, then mark them read
python3 skills/email/scripts/email_read.py --unseen --full --mark-seen

# search helpers (ANDed) + raw IMAP criteria
python3 skills/email/scripts/email_read.py --from boss@acme.com --since 01-Jun-2026
python3 skills/email/scripts/email_read.py --search 'SUBJECT invoice UNSEEN' --full

# one specific message + save its attachments
python3 skills/email/scripts/email_read.py --uid 12345 --save-attachments downloads/
python3 skills/email/scripts/email_read.py --list-mailboxes
```
Output is one line per message: `UID <uid> | <date> | <From> | <Subject>`; `--full`
appends the decoded text body (prefers `text/plain`, falls back to stripped HTML).
**Reading peeks by default** (uses `BODY.PEEK`, so messages stay unread) — pass
`--mark-seen` to actually mark them read. Convenience filters: `--unseen`, `--from`,
`--subject`, `--since`, `--mailbox` (default `INBOX`), `--limit` (default 10, most
recent). For complex queries use `--search` with raw IMAP criteria.

## Gotchas

- **Auth fails** ⇒ you're almost certainly using your normal password. Create an
  **app password** (needs 2FA on) — see `references/providers.md`.
- **Outlook/Office365 personal & many tenants** have disabled basic-auth IMAP/SMTP;
  there app passwords may not exist and OAuth2 is required. Gmail, iCloud, Yahoo,
  Fastmail, and Zoho all work with app passwords today.
- **Sent folder** — SMTP send doesn't add to Sent; pass `--save-sent` if you want a
  copy there.
- **Marking read** — `email_read.py` peeks by default; only `--mark-seen` changes
  flags. Good for polling without disturbing the user's unread state.
- **Rate limits** — Gmail caps ~500 recipients/day on free accounts; don't bulk-send.
- **Kubernetes pods** — the stock NetworkPolicy in `ops/agent.yaml` only allows
  egress on 53/443/80, so IMAP (993) and SMTP (587/465) are blocked from a
  deployed agent until those ports are added to the policy.
- **Attachments** are read from the workspace; size limits are provider-dependent
  (~25 MB typical).

See `references/providers.md` for the host/port table, per-provider app-password
steps, the IMAP search cheat-sheet, and a `curl`-only send alternative.
