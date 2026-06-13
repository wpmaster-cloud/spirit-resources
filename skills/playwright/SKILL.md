---
name: playwright
requires: python3, node
description: >
  Install and drive a real browser with Playwright (Python) on any machine — Linux, macOS, or Windows, on x86-64 or arm64. Use whenever a task needs actual browser automation rather than just reading a page: clicking through multi-step flows, filling and submitting forms, logging in and reusing a session, waiting on JavaScript-rendered content, capturing screenshots or PDFs, or scripting end-to-end interactions. Covers downloading/installing Playwright and its browser binaries (including the per-OS system-dependency caveats), the handy CLI one-liners (screenshot/pdf/codegen), and a scripting template. For simply turning a page into clean markdown or extracting structured data, prefer the web-extraction skill (Defuddle/Crawl4AI) instead.
---

# Playwright

Playwright drives **Chromium, Firefox, and WebKit** through one API. Unlike a plain HTTP fetch, it runs a real browser engine, so it sees JavaScript-rendered content and can *act* on a page — click, type, navigate, wait, and capture. This skill covers installing it cleanly on any platform and using it from Python.

## In the spirit cluster: use the shared browser-go server first

If you are a deployed spirit agent (Alpine/musl + arm64), **you cannot install
Playwright or Chromium locally** — the prebuilt browsers don't exist for that
target. Instead there is a shared browser service, `browser-go`, that runs one
real Chromium and exposes it over HTTP. Drive it with `curl` — no install:

```bash
B=http://browser-go.spirit-browser.svc.cluster.local
H="Authorization: Bearer $BROWSER_TOKEN"     # ask the operator for the token

# Just need the rendered content? One call (its own isolated context):
curl -s -H "$H" $B/render -d '{"url":"https://example.com"}'   # {url,title,text,html}
curl -s -H "$H" $B/shot   -d '{"url":"https://example.com","full_page":true}' -o shot.png

# Multi-step flow (login, forms)? Open a session = your own isolated browser
# context; /act runs goto|click|fill|press|select|wait|text|content|eval:
SP=$(curl -s -H "$H" $B/sessions); SID=$(jq -r .session_id <<<"$SP"); PID=$(jq -r .page_id <<<"$SP")
P=$B/sessions/$SID/pages/$PID
curl -s -H "$H" $P/act -d '{"action":"goto","url":"https://example.com/login"}'
curl -s -H "$H" $P/act -d '{"action":"fill","selector":"#user","value":"alice"}'
curl -s -H "$H" $P/act -d '{"action":"click","selector":"button[type=submit]"}'
curl -s -X DELETE -H "$H" $B/sessions/$SID     # free it when done
```

Each session is isolated from other agents (own cookies/storage), so many
agents use the one browser in parallel safely. Full API in the browser-go
README. The rest of this skill (local install, the Python API) applies when
you're on a glibc machine — a dev box, a CI runner, or a non-musl container.

## When to use Playwright vs web-extraction

These overlap (both can load a page in a browser), so pick the lighter tool when you can:

| Goal | Reach for |
|---|---|
| Turn a readable page into clean markdown | **web-extraction → Defuddle** |
| Extract structured records (products, listings) at scale | **web-extraction → Crawl4AI** |
| Click through a flow, fill a form, log in, multi-step interaction | **Playwright** |
| Wait for a specific JS-rendered element, then act on it | **Playwright** |
| Capture a screenshot or print a page to PDF | **Playwright** (CLI one-liner) |
| Save a login session and reuse it across runs | **Playwright** (storage state) |

Rule of thumb: if you just need the *content*, use web-extraction. If you need to *operate* the browser, use Playwright. (Crawl4AI is itself built on Playwright — this skill is for when you want direct, precise control.)

## Install

Playwright is a Python package plus a set of **prebuilt browser binaries** it downloads separately. The package install is identical everywhere; the only cross-platform wrinkle is the system libraries the browsers need (see the matrix below).

```bash
# 1. The Python library
pip install playwright            # or: python -m pip install playwright

# 2. The browser binaries (downloads Chromium, Firefox, WebKit)
playwright install                # all three engines
playwright install chromium       # just one — smaller/faster, usually enough
```

If `playwright` isn't on PATH after the pip install, call it as a module: `python -m playwright install chromium`.

**PEP 668 ("externally-managed-environment").** On macOS/Homebrew Python and recent Debian/Ubuntu/Fedora, a bare `pip install` is blocked to protect the system Python. Use a virtual environment (cleanest, recommended) and run everything through it:

```bash
python3 -m venv .venv && . .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install playwright && playwright install chromium
```

Then invoke scripts with the venv's interpreter (`.venv/bin/python script.py`). Alternatives if you can't use a venv: `pipx install playwright`, or `pip install --user playwright`, or — last resort — `pip install --break-system-packages playwright`.

### Cross-platform / cross-arch matrix

Prebuilt binaries exist for the common targets, so the same two commands work on each. The difference is **system dependencies** — shared libraries the browsers link against:

| Platform | Arch | Browser binaries | System deps |
|---|---|---|---|
| macOS 14+ | x86-64 & arm64 (Apple Silicon) | prebuilt | none needed |
| Windows 11 / Server 2019+ (or WSL) | x86-64 | prebuilt | none needed |
| Debian 12/13, Ubuntu 22.04/24.04 | x86-64 & arm64 | prebuilt | use `--with-deps` (see below) |
| Other Linux (Fedora, Arch, RHEL, …) | x86-64 & arm64 | prebuilt | install libs manually |
| Alpine / musl libc | — | not supported | use a glibc-based image instead |

**On macOS and Windows you're done after `playwright install`** — no system deps.

**On Debian/Ubuntu**, install the OS libraries too. This is the one command people get wrong by running it everywhere — it shells out to `apt`, so it *only* works on Debian/Ubuntu and needs root:

```bash
playwright install --with-deps chromium     # downloads browser AND apt-installs its libs
# or, separately:
sudo playwright install-deps                # just the system libs (Debian/Ubuntu only)
```

**On other Linux distros** there is no `install-deps` support. Install the browser binaries normally (`playwright install`), then add the shared libraries with the distro's own package manager. If a launch fails, the error names the missing `.so` files — map those to packages (commonly `nss`, `nspr`, `atk`, `at-spi2-atk`, `cups-libs`, `libdrm`, `libxkbcommon`, `mesa-libgbm`, `pango`, `alsa-lib`, plus GTK libs for non-headless). `ldd` on the browser binary helps find gaps.

### Where browsers are stored

Binaries land in a per-OS cache, not in your project:

- Linux: `~/.cache/ms-playwright`
- macOS: `~/Library/Caches/ms-playwright`
- Windows: `%USERPROFILE%\AppData\Local\ms-playwright`

Override the location with `PLAYWRIGHT_BROWSERS_PATH` (useful for shared installs or CI caching). Verify what's installed with `scripts/check_install.py`.

### Already have it?

Crawl4AI (in the **web-extraction** skill) bundles Playwright and runs `playwright install` during `crawl4ai-setup`. So on a machine where Crawl4AI is set up, the Python package and Chromium may already be present — run `scripts/check_install.py` before downloading again.

## CLI one-liners (no script needed)

The `playwright` command does the most common one-off jobs directly:

```bash
playwright screenshot --full-page https://example.com shot.png
playwright pdf https://example.com page.pdf        # Chromium, headless only
playwright codegen https://example.com             # opens a browser, records your clicks → Python code
playwright open https://example.com                # just open a page in a controlled browser
```

`codegen` is the fastest way to author a script: interact with the page by hand and it prints the matching Playwright Python calls, which you then adapt.

## Scripting (Python)

The core loop is always: **launch → new page → navigate → act/wait → read or capture → close.** Use the sync API for simple linear scripts; use the async API when crawling many pages concurrently.

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)   # firefox / webkit also available
    page = browser.new_page()
    page.goto("https://example.com", wait_until="domcontentloaded")

    page.wait_for_selector("h1")                 # wait for JS-rendered content
    print(page.title())
    print(page.inner_text("body"))

    page.screenshot(path="out.png", full_page=True)
    browser.close()
```

Key building blocks:
- **Locators (prefer these):** `page.get_by_role("button", name="Sign in")`, `page.get_by_text(...)`, `page.locator("css=...")`. They auto-wait for the element, which removes most flakiness.
- **Acting:** `.click()`, `.fill(value)`, `.type(text)`, `.press("Enter")`, `.check()`, `.select_option(...)`.
- **Waiting:** `page.wait_for_selector(sel)`, `page.wait_for_load_state("networkidle")`, `page.wait_for_url(...)`. Prefer waiting on a concrete element/URL over fixed sleeps.
- **Reading:** `page.content()` (full HTML), `page.inner_text(sel)`, `locator.all_inner_texts()`, `page.evaluate("() => ...")` to run JS in the page.
- **Sessions:** save cookies/localStorage with `context.storage_state(path="state.json")`, then reuse via `browser.new_context(storage_state="state.json")` so you log in once.

See `scripts/` for runnable templates:
- **`check_install.py`** — confirm Playwright + which browsers are installed, print the cache path. Run this first.
- **`quickstart.py <url>`** — launch, navigate, print title + text, save a screenshot. The minimal end-to-end example.
- **`patterns.py`** — annotated recipes: form fill + submit, login then save/reuse storage state, wait-for-dynamic-content, concurrent multi-page crawl (async), and print-to-PDF.

## Troubleshooting

- **`Executable doesn't exist … run "playwright install"`** — the package is installed but the browser binary isn't. Run `playwright install chromium` (check `PLAYWRIGHT_BROWSERS_PATH` if you set it).
- **Linux launch fails with missing `lib*.so`** — system deps. Debian/Ubuntu: `playwright install --with-deps chromium`. Other distros: install the named libraries manually (see matrix above).
- **Running as root / in a container** — Chromium's sandbox can fail. Launch with `p.chromium.launch(chromium_sandbox=False)` or `args=["--no-sandbox"]`. Prefer a non-root user when possible.
- **Headless behaves differently from headed** — some sites gate on it. Try `launch(headless=False)` to debug, and set a realistic `user_agent`/viewport via `browser.new_context(...)`.
- **Element not found / race conditions** — you're probably acting before render. Use locators (they auto-wait) or `wait_for_selector`/`wait_for_load_state` instead of `time.sleep`.
- **PDF is empty or errors** — `page.pdf()` / `playwright pdf` only works in **headless Chromium**, not Firefox/WebKit.
- **Apple Silicon / arm64** — fully supported; no special flags. If `pip` pulled a mismatched wheel in an emulated shell, reinstall in a native arm64 Python.

## Keeping current

Update both the package and the browsers together, since binaries are pinned per version:

```bash
pip install -U playwright && playwright install
```
