#!/usr/bin/env python3
"""Verify the Playwright install and report which browsers are present.

Run this BEFORE downloading browsers — Crawl4AI (web-extraction skill) may have
already installed them. Exits 0 if at least one engine launches, 1 otherwise.

    python check_install.py
"""
import os
import platform
import sys


def main() -> int:
    print(f"Platform: {platform.system()} {platform.machine()}  Python {platform.python_version()}")

    try:
        import playwright  # noqa: F401
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("✗ playwright package not installed.  ->  pip install playwright")
        return 1
    print("✓ playwright package importable")

    cache = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if cache:
        print(f"Browser cache (PLAYWRIGHT_BROWSERS_PATH): {cache}")
    else:
        default = {
            "Linux": "~/.cache/ms-playwright",
            "Darwin": "~/Library/Caches/ms-playwright",
            "Windows": r"%USERPROFILE%\AppData\Local\ms-playwright",
        }.get(platform.system(), "(unknown)")
        print(f"Browser cache (default): {default}")

    ok = False
    with sync_playwright() as p:
        for name in ("chromium", "firefox", "webkit"):
            engine = getattr(p, name)
            try:
                browser = engine.launch(headless=True)
                version = browser.version
                browser.close()
                print(f"✓ {name:8s} launches (v{version})")
                ok = True
            except Exception as exc:  # noqa: BLE001
                first_line = str(exc).strip().splitlines()[0]
                print(f"✗ {name:8s} not available: {first_line}")

    if not ok:
        print('\nNo engine launched.  ->  playwright install chromium')
        print("(On Debian/Ubuntu add system libs: playwright install --with-deps chromium)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
