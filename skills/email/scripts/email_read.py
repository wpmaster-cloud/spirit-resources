#!/usr/bin/env python3
"""Read / search email via IMAP using only the Python standard library.

Credentials come from the environment or email/config.env (see SKILL.md).
Reads PEEK by default (does not mark messages read) unless --mark-seen is given.

Examples:
  email_read.py                                  # 10 most recent inbox headers
  email_read.py --unseen --full --mark-seen      # unread, with body, then mark read
  email_read.py --from boss@acme.com --since 01-Jun-2026
  email_read.py --search 'SUBJECT invoice UNSEEN' --full
  email_read.py --uid 12345 --save-attachments downloads/
  email_read.py --list-mailboxes
"""
import argparse
import email
import email.policy
import os
import re
import sys
from email.header import decode_header, make_header

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _email_common import load_config, imap_connect  # noqa: E402


def dh(value):
    """Decode a possibly RFC2047-encoded header into a plain string."""
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:  # noqa: BLE001
        return str(value)


def strip_html(s):
    import html as htmlmod
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = htmlmod.unescape(s)
    return re.sub(r"[ \t]+\n", "\n", re.sub(r"\n[ \t]*\n\s*", "\n\n", s)).strip()


def body_text(msg):
    if msg.is_multipart():
        plain = html = None
        for part in msg.walk():
            if "attachment" in str(part.get("Content-Disposition") or ""):
                continue
            ctype = part.get_content_type()
            if ctype == "text/plain" and plain is None:
                plain = part.get_content()
            elif ctype == "text/html" and html is None:
                html = part.get_content()
        if plain:
            return plain.strip()
        if html:
            return strip_html(html)
        return ""
    content = msg.get_content()
    if msg.get_content_type() == "text/html":
        return strip_html(content)
    return (content or "").strip()


def build_criteria(args):
    crit = []
    if args.unseen:
        crit += ["UNSEEN"]
    if args.from_:
        crit += ["FROM", args.from_]
    if args.subject:
        crit += ["SUBJECT", args.subject]
    if args.since:
        crit += ["SINCE", args.since]
    if args.search:
        crit += args.search.split()
    return crit or ["ALL"]


def extract_raw(msgdata):
    for part in msgdata:
        if isinstance(part, tuple) and len(part) >= 2:
            return part[1]
    return None


def save_attachments(msg, outdir, uid):
    os.makedirs(outdir, exist_ok=True)
    saved = []
    for part in msg.walk():
        disp = str(part.get("Content-Disposition") or "")
        if "attachment" not in disp and not part.get_filename():
            continue
        name = dh(part.get_filename() or f"{uid}.bin")
        name = os.path.basename(name)
        payload = part.get_payload(decode=True)
        if payload is None:
            continue
        dest = os.path.join(outdir, name)
        with open(dest, "wb") as f:
            f.write(payload)
        saved.append(dest)
    for s in saved:
        print(f"    saved attachment: {s}")


def main():
    p = argparse.ArgumentParser(description="Read / search email via IMAP.")
    p.add_argument("--mailbox", default="INBOX")
    p.add_argument("--search", help="raw IMAP search, e.g. 'UNSEEN' or 'FROM x SUBJECT y'")
    p.add_argument("--unseen", action="store_true", help="only unread messages")
    p.add_argument("--from", dest="from_", help="convenience FROM filter")
    p.add_argument("--subject", help="convenience SUBJECT filter (single token)")
    p.add_argument("--since", help="convenience SINCE date, e.g. 01-Jun-2026")
    p.add_argument("--limit", type=int, default=10, help="max messages, most recent (0 = all)")
    p.add_argument("--uid", help="fetch one specific UID (implies --full)")
    p.add_argument("--full", action="store_true", help="show the decoded body of each message")
    p.add_argument("--mark-seen", action="store_true", help="mark fetched messages read (default: peek)")
    p.add_argument("--save-attachments", metavar="DIR", help="save attachments to DIR")
    p.add_argument("--list-mailboxes", action="store_true")
    args = p.parse_args()

    cfg = load_config()
    M = imap_connect(cfg)
    try:
        if args.list_mailboxes:
            typ, data = M.list()
            for d in data or []:
                print(d.decode(errors="replace"))
            return

        M.select(args.mailbox, readonly=not args.mark_seen)

        if args.uid:
            uids = [args.uid.encode()]
            args.full = True
        else:
            typ, data = M.uid("SEARCH", None, *build_criteria(args))
            uids = data[0].split() if data and data[0] else []
            if args.limit and args.limit > 0:
                uids = uids[-args.limit:]

        if not uids:
            print("(no messages match)")
            return

        fetchspec = "(RFC822)" if args.mark_seen else "(BODY.PEEK[])"
        for uid in uids:
            typ, msgdata = M.uid("FETCH", uid, fetchspec)
            raw = extract_raw(msgdata)
            if raw is None:
                continue
            msg = email.message_from_bytes(raw, policy=email.policy.default)
            print(f"UID {uid.decode()} | {dh(msg.get('Date'))} | "
                  f"{dh(msg.get('From'))} | {dh(msg.get('Subject'))}")
            if args.full:
                print("-" * 70)
                print(body_text(msg))
                print("=" * 70)
            if args.save_attachments:
                save_attachments(msg, args.save_attachments, uid.decode())
    finally:
        try:
            M.logout()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
