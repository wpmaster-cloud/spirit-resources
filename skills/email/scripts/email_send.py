#!/usr/bin/env python3
"""Send an email via SMTP using only the Python standard library.

Credentials come from the environment or email/config.env (see SKILL.md).

Examples:
  email_send.py --to a@x.com --subject "Hi" --body "hello"
  email_send.py --to a@x.com --cc b@x.com --subject Q2 --html-file r.html --attach r.pdf
  echo "body" | email_send.py --to a@x.com --subject Hi --stdin
  email_send.py --to a@x.com --subject test --body hi --dry-run
"""
import argparse
import mimetypes
import os
import sys
import time
from email.message import EmailMessage
from email.utils import formataddr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _email_common import load_config, smtp_connect, imap_connect  # noqa: E402


def split_addrs(values):
    out = []
    for v in values or []:
        out += [a.strip() for a in v.replace(";", ",").split(",") if a.strip()]
    return out


def build_message(args, cfg):
    text = None
    if args.stdin:
        text = sys.stdin.read()
    elif args.body is not None:
        text = args.body
    elif args.body_file:
        with open(args.body_file, encoding="utf-8") as f:
            text = f.read()

    html = None
    if args.html is not None:
        html = args.html
    elif args.html_file:
        with open(args.html_file, encoding="utf-8") as f:
            html = f.read()

    if text is None and html is None:
        sys.exit("error: provide a body (--body/--body-file/--stdin or --html/--html-file)")

    msg = EmailMessage()
    from_name = args.from_name or cfg["from_name"]
    msg["From"] = formataddr((from_name, cfg["address"])) if from_name else cfg["address"]
    to = split_addrs(args.to)
    cc = split_addrs(args.cc)
    if to:
        msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    if args.reply_to:
        msg["Reply-To"] = args.reply_to
    msg["Subject"] = args.subject

    if text is not None:
        msg.set_content(text)
    if html is not None:
        if text is None:
            msg.set_content("This message is best viewed in an HTML-capable client.")
        msg.add_alternative(html, subtype="html")

    for path in args.attach or []:
        ctype, _ = mimetypes.guess_type(path)
        maintype, subtype = (ctype.split("/", 1) if ctype else ("application", "octet-stream"))
        with open(path, "rb") as f:
            data = f.read()
        msg.add_attachment(data, maintype=maintype, subtype=subtype,
                           filename=os.path.basename(path))
    return msg, to, cc, split_addrs(args.bcc)


def save_to_sent(cfg, msg):
    import imaplib
    candidates = ["Sent", "[Gmail]/Sent Mail", "Sent Items", "Sent Messages", "INBOX.Sent"]
    try:
        M = imap_connect(cfg)
    except Exception as e:  # noqa: BLE001
        print(f"  (save-sent skipped: IMAP login failed: {e})")
        return
    try:
        for name in candidates:
            try:
                typ, _ = M.append(name, "(\\Seen)",
                                  imaplib.Time2Internaldate(time.time()), msg.as_bytes())
                if typ == "OK":
                    print(f"  saved a copy to {name}")
                    return
            except Exception:  # noqa: BLE001
                continue
        print("  (save-sent: no standard Sent mailbox accepted the message)")
    finally:
        try:
            M.logout()
        except Exception:  # noqa: BLE001
            pass


def main():
    p = argparse.ArgumentParser(description="Send an email via SMTP.")
    p.add_argument("--to", action="append", help="recipient(s); repeatable or comma-separated")
    p.add_argument("--cc", action="append")
    p.add_argument("--bcc", action="append")
    p.add_argument("--subject", default="")
    p.add_argument("--body", help="plain-text body")
    p.add_argument("--body-file")
    p.add_argument("--html", help="HTML body")
    p.add_argument("--html-file")
    p.add_argument("--stdin", action="store_true", help="read plain-text body from stdin")
    p.add_argument("--attach", action="append", help="file to attach; repeatable")
    p.add_argument("--from-name", help="display name for the From header")
    p.add_argument("--reply-to")
    p.add_argument("--save-sent", action="store_true",
                   help="best-effort: append a copy to the Sent mailbox via IMAP")
    p.add_argument("--dry-run", action="store_true",
                   help="build the message and print a summary without sending")
    args = p.parse_args()

    cfg = load_config()
    msg, to, cc, bcc = build_message(args, cfg)
    recipients = to + cc + bcc
    if not recipients:
        sys.exit("error: at least one --to/--cc/--bcc recipient is required")

    if args.dry_run:
        print("DRY RUN (not sent)")
        print(f"  From:    {msg['From']}")
        print(f"  To:      {', '.join(to) or '-'}")
        print(f"  Cc:      {', '.join(cc) or '-'}")
        print(f"  Bcc:     {', '.join(bcc) or '-'}")
        print(f"  Subject: {args.subject}")
        n_attach = len(args.attach or [])
        has_html = args.html is not None or bool(args.html_file)
        print(f"  Parts:   html={has_html} attachments={n_attach}")
        print(f"  SMTP:    {cfg['smtp_host']}:{cfg['smtp_port']} ({cfg['smtp_security']})")
        return

    s = smtp_connect(cfg)
    try:
        s.send_message(msg, from_addr=cfg["address"], to_addrs=recipients)
    finally:
        try:
            s.quit()
        except Exception:  # noqa: BLE001
            pass
    print(f"sent: to={', '.join(recipients)} subject={args.subject!r}")
    if args.save_sent:
        save_to_sent(cfg, msg)


if __name__ == "__main__":
    main()
