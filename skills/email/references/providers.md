# Email providers, app passwords & IMAP search

## Host / port presets

Set `EMAIL_PROVIDER` to one of these and the scripts fill in the hosts. For
anything else, set `IMAP_HOST/IMAP_PORT/SMTP_HOST/SMTP_PORT` directly.

| Provider (`EMAIL_PROVIDER`) | IMAP | SMTP | App password? |
|---|---|---|---|
| `gmail` | imap.gmail.com:993 | smtp.gmail.com:587 | **required** (2FA on) |
| `outlook` / `office365` / `hotmail` | outlook.office365.com:993 | smtp.office365.com:587 | often **blocked** — OAuth may be required |
| `yahoo` | imap.mail.yahoo.com:993 | smtp.mail.yahoo.com:465 | **required** |
| `icloud` | imap.mail.me.com:993 | smtp.mail.me.com:587 | **required** (app-specific) |
| `fastmail` | imap.fastmail.com:993 | smtp.fastmail.com:465 | **required** |
| `zoho` | imap.zoho.com:993 | smtp.zoho.com:465 | recommended |
| `gmx` | imap.gmx.com:993 | mail.gmx.com:587 | enable IMAP/POP first |

Port 465 ⇒ implicit SSL; 587 ⇒ STARTTLS. Override with `SMTP_SECURITY=ssl|starttls`.

## Creating an app password

Plain-password IMAP/SMTP login is disabled by most providers. With 2-factor auth
enabled, generate an app password and use it as `EMAIL_PASSWORD`:

- **Gmail**: myaccount.google.com → Security → 2-Step Verification (turn on) →
  *App passwords* → generate. Use the 16-char value (spaces optional).
- **iCloud**: account.apple.com → Sign-In & Security → *App-Specific Passwords*.
- **Yahoo**: Account security → *Generate app password*.
- **Fastmail**: Settings → Privacy & Security → *App passwords* (give it Mail scope).
- **Outlook/Office365**: personal accounts and many work tenants have disabled
  basic auth entirely — app passwords may be unavailable and OAuth2 is then the
  only path (out of scope for this stdlib skill). If your tenant still allows it,
  create the app password under Security settings.

## IMAP search cheat-sheet

Pass these to `email_read.py --search '<criteria>'` (multiple are ANDed). Common keys:

```
ALL                      every message
UNSEEN / SEEN            unread / read
FROM "boss@acme.com"     sender contains
TO / CC "x@y.com"        recipient contains
SUBJECT "invoice"        subject contains
BODY "refund"            body contains
TEXT "term"              headers or body contain
SINCE 01-Jun-2026        on/after a date (DD-Mon-YYYY)
BEFORE 01-Jul-2026       before a date
ON 15-Jun-2026           exactly that date
FLAGGED / UNFLAGGED      starred or not
LARGER 1000000           bigger than N bytes
HEADER "List-Id" "x"     match an arbitrary header
NOT / OR <a> <b>         boolean combinators
```

Examples:
```bash
email_read.py --search 'UNSEEN FROM github.com'
email_read.py --search 'SINCE 01-Jun-2026 SUBJECT receipt'
email_read.py --search 'OR FROM a@x.com FROM b@x.com'
```
The `--from`, `--subject`, `--since`, and `--unseen` flags are convenience builders
for the same thing (single-token values; use `--search` for quoted/multi-word).

## curl-only send (alternative)

If you can't use Python, `curl` (built with SMTP support) can send a pre-built MIME
file:

```bash
printf 'From: you@x.com\nTo: them@y.com\nSubject: hi\n\nbody\n' > /tmp/msg.eml
curl --ssl-reqd --url "smtps://smtp.gmail.com:465" \
  --user "you@gmail.com:APP_PASSWORD" \
  --mail-from you@gmail.com --mail-rcpt them@y.com \
  --upload-file /tmp/msg.eml
```
Reading via curl IMAP is possible but parsing MIME by hand is painful — prefer
`email_read.py`. The stdlib scripts are the recommended path for both directions.

## Gotchas

- **`AUTHENTICATIONFAILED`** ⇒ wrong/normal password — use an app password.
- **Office365 `LOGIN failed`** ⇒ tenant disabled basic auth; OAuth required.
- **Gmail "Lots of mail from unknown senders"/limits** ⇒ free accounts cap ~500
  recipients/day; don't bulk-send.
- **Sent folder** isn't populated by SMTP; pass `--save-sent` to append a copy.
- **Folder names vary** (`Sent` vs `[Gmail]/Sent Mail` vs `Sent Items`) — use
  `email_read.py --list-mailboxes` to see the exact names for your account.
