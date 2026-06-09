#!/usr/bin/env python3
"""Minimal end-to-end Playwright example: launch -> navigate -> read -> capture.

    python quickstart.py https://example.com [out.png]

Prints the page title and a snippet of visible text, and saves a full-page
screenshot (default: shot.png). Headless Chromium; falls back to no-sandbox
when running as root / in a container.
"""
import sys

from playwright.sync_api import sync_playwright


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    url = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "shot.png"

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(headless=True)
        except Exception:
            # Common in containers / as root: disable the Chromium sandbox.
            browser = p.chromium.launch(headless=True, chromium_sandbox=False)

        page = browser.new_page()
        page.goto(url, wait_until="domcontentloaded")
        page.wait_for_load_state("networkidle")

        print(f"URL:    {page.url}")
        print(f"Title:  {page.title()}")
        text = page.inner_text("body").strip()
        print(f"\nText (first 800 chars):\n{text[:800]}")

        page.screenshot(path=out, full_page=True)
        print(f"\nScreenshot saved -> {out}")
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
