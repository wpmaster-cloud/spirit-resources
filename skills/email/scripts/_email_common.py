#!/usr/bin/env python3
"""Shared credential + provider-host resolution for the email skill.

Not run directly — imported by email_setup.py / email_send.py / email_read.py.
Only the Python standard library is used.
"""
import os
import sys
import ssl
import imaplib
import smtplib

# Preset IMAP/SMTP hosts keyed by EMAIL_PROVIDER. (host, port)
PROVIDERS = {
    "gmail":      {"imap": ("imap.gmail.com", 993),          "smtp": ("smtp.gmail.com", 587)},
    "googlemail": {"imap": ("imap.gmail.com", 993),          "smtp": ("smtp.gmail.com", 587)},
    "outlook":    {"imap": ("outlook.office365.com", 993),   "smtp": ("smtp.office365.com", 587)},
    "office365":  {"imap": ("outlook.office365.com", 993),   "smtp": ("smtp.office365.com", 587)},
    "hotmail":    {"imap": ("outlook.office365.com", 993),   "smtp": ("smtp.office365.com", 587)},
    "yahoo":      {"imap": ("imap.mail.yahoo.com", 993),     "smtp": ("smtp.mail.yahoo.com", 465)},
    "icloud":     {"imap": ("imap.mail.me.com", 993),        "smtp": ("smtp.mail.me.com", 587)},
    "fastmail":   {"imap": ("imap.fastmail.com", 993),       "smtp": ("smtp.fastmail.com", 465)},
    "zoho":       {"imap": ("imap.zoho.com", 993),           "smtp": ("smtp.zoho.com", 465)},
    "gmx":        {"imap": ("imap.gmx.com", 993),            "smtp": ("mail.gmx.com", 587)},
}

# Config-file search order (env vars always take precedence). Paths are relative to
# the workspace root (run_command cwd) and to this script's parent (the skill dir).
_CONFIG_CANDIDATES = [
    "email/config.env",
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config.env")),
]


def _parse_env_file(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out


def load_config():
    env = dict(os.environ)
    # Fill missing credentials from a config file without overriding the environment.
    if not env.get("EMAIL_ADDRESS") or not env.get("EMAIL_PASSWORD"):
        for cand in [env.get("EMAIL_CONFIG")] + _CONFIG_CANDIDATES:
            if cand and os.path.isfile(cand):
                for k, v in _parse_env_file(cand).items():
                    env.setdefault(k, v)
                break

    address = (env.get("EMAIL_ADDRESS") or "").strip()
    password = env.get("EMAIL_PASSWORD") or ""
    if not address or not password:
        sys.exit("error: EMAIL_ADDRESS and EMAIL_PASSWORD must be set "
                 "(env vars or email/config.env). See skills/email/SKILL.md")

    provider = (env.get("EMAIL_PROVIDER") or "").strip().lower()
    preset = PROVIDERS.get(provider, {})
    p_imap = preset.get("imap", (None, 993))
    p_smtp = preset.get("smtp", (None, 587))

    imap_host = (env.get("IMAP_HOST") or p_imap[0])
    imap_port = int(env.get("IMAP_PORT") or p_imap[1])
    smtp_host = (env.get("SMTP_HOST") or p_smtp[0])
    smtp_port = int(env.get("SMTP_PORT") or p_smtp[1])
    security = (env.get("SMTP_SECURITY") or ("ssl" if smtp_port == 465 else "starttls")).lower()

    return {
        "address": address,
        "password": password,
        "imap_host": imap_host,
        "imap_port": imap_port,
        "smtp_host": smtp_host,
        "smtp_port": smtp_port,
        "smtp_security": security,
        "from_name": (env.get("EMAIL_FROM_NAME") or "").strip(),
        "provider": provider,
    }


def imap_connect(cfg):
    if not cfg["imap_host"]:
        sys.exit("error: no IMAP host (set EMAIL_PROVIDER or IMAP_HOST/IMAP_PORT)")
    M = imaplib.IMAP4_SSL(cfg["imap_host"], cfg["imap_port"])
    M.login(cfg["address"], cfg["password"])
    return M


def smtp_connect(cfg):
    if not cfg["smtp_host"]:
        sys.exit("error: no SMTP host (set EMAIL_PROVIDER or SMTP_HOST/SMTP_PORT)")
    if cfg["smtp_security"] == "ssl":
        s = smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=30)
    else:
        s = smtplib.SMTP(cfg["smtp_host"], cfg["smtp_port"], timeout=30)
        s.ehlo()
        s.starttls(context=ssl.create_default_context())
        s.ehlo()
    s.login(cfg["address"], cfg["password"])
    return s
