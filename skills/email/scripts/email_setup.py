#!/usr/bin/env python3
"""Verify email credentials: log into IMAP (and list mailboxes) and SMTP.

Run this once after setting EMAIL_ADDRESS / EMAIL_PASSWORD (+ EMAIL_PROVIDER or
explicit hosts). Uses only the Python standard library.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _email_common import load_config, imap_connect, smtp_connect, PROVIDERS  # noqa: E402


def main():
    cfg = load_config()
    print(f"address:  {cfg['address']}")
    print(f"provider: {cfg['provider'] or '(custom hosts)'}")
    print(f"IMAP:     {cfg['imap_host']}:{cfg['imap_port']}")
    print(f"SMTP:     {cfg['smtp_host']}:{cfg['smtp_port']} ({cfg['smtp_security']})")
    print()

    ok = True

    print("== IMAP login ==")
    try:
        M = imap_connect(cfg)
        try:
            typ, data = M.list()
            boxes = [d.decode(errors="replace").split(' "/" ')[-1].strip('"')
                     for d in (data or [])]
            print(f"  ok — {len(boxes)} mailboxes: " + ", ".join(boxes[:12])
                  + (" …" if len(boxes) > 12 else ""))
        finally:
            try:
                M.logout()
            except Exception:  # noqa: BLE001
                pass
    except Exception as e:  # noqa: BLE001
        ok = False
        print(f"  FAILED: {e}")

    print("== SMTP login ==")
    try:
        s = smtp_connect(cfg)
        try:
            print("  ok — authenticated, ready to send")
        finally:
            try:
                s.quit()
            except Exception:  # noqa: BLE001
                pass
    except Exception as e:  # noqa: BLE001
        ok = False
        print(f"  FAILED: {e}")

    if not ok:
        print()
        print("Login failed. Most often this means a normal password was used —")
        print("create an APP PASSWORD (with 2FA enabled). See references/providers.md.")
        if cfg["provider"] and cfg["provider"] not in PROVIDERS:
            print(f"Also: '{cfg['provider']}' isn't a known preset; set IMAP_HOST/SMTP_HOST.")
        sys.exit(1)

    print()
    print("All good. Try:  python3 skills/email/scripts/email_read.py")


if __name__ == "__main__":
    main()
