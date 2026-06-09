#!/usr/bin/env python3
"""Annotated Playwright recipes — copy/adapt the function you need.

These are reference implementations, not a CLI. Import them or paste the body
into your own script. Each shows a common automation shape and the idiomatic,
flake-resistant way to do it (locators + explicit waits, not time.sleep).

Recipes:
  fill_and_submit_form   – type into fields, click submit, read the result
  login_and_save_state   – log in once, persist the session, reuse it later
  wait_for_dynamic       – wait on JS-rendered content before reading it
  page_to_pdf            – print a page to PDF (headless Chromium only)
  crawl_many_async       – fetch many URLs concurrently with the async API
"""
from playwright.sync_api import sync_playwright


def fill_and_submit_form(url: str) -> str:
    """Fill a form and return the resulting page text.

    Locators auto-wait for elements, so no manual sleeps are needed. Prefer
    role/label-based locators — they survive markup changes better than CSS.
    """
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(url)

        page.get_by_label("Email").fill("user@example.com")
        page.get_by_label("Message").fill("Hello from Playwright")
        page.get_by_role("button", name="Send").click()

        page.wait_for_load_state("networkidle")
        result = page.inner_text("body")
        browser.close()
        return result


def login_and_save_state(login_url: str, state_path: str = "state.json") -> None:
    """Log in once and persist cookies + localStorage to `state_path`.

    Reuse it later with browser.new_context(storage_state=state_path) so you
    skip the login on every subsequent run. Treat the state file as a secret.
    """
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        page = context.new_page()
        page.goto(login_url)

        page.get_by_label("Username").fill("myuser")
        page.get_by_label("Password").fill("mypass")
        page.get_by_role("button", name="Sign in").click()
        page.wait_for_url("**/dashboard**")  # wait for the post-login page

        context.storage_state(path=state_path)
        browser.close()


def use_saved_state(url: str, state_path: str = "state.json") -> str:
    """Open an authenticated page using a previously saved storage state."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(storage_state=state_path)
        page = context.new_page()
        page.goto(url)
        text = page.inner_text("body")
        browser.close()
        return text


def wait_for_dynamic(url: str, selector: str) -> str:
    """Wait for a specific JS-rendered element, then return its text.

    Waiting on a concrete selector/URL is far more reliable than a fixed delay,
    because it tracks the page's actual state rather than guessing a duration.
    """
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(url, wait_until="domcontentloaded")
        page.wait_for_selector(selector, state="visible", timeout=30_000)
        text = page.locator(selector).inner_text()
        browser.close()
        return text


def page_to_pdf(url: str, out: str = "page.pdf") -> None:
    """Render a page to PDF. Only works in headless Chromium (not FF/WebKit)."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(url, wait_until="networkidle")
        page.pdf(path=out, format="A4", print_background=True)
        browser.close()


async def crawl_many_async(urls, max_concurrent: int = 5):
    """Fetch many URLs concurrently. Returns [(url, title, char_count), ...].

    Use the async API for scale: one browser, many contexts, bounded by a
    semaphore so you don't open hundreds of pages at once.
    """
    import asyncio

    from playwright.async_api import async_playwright

    sem = asyncio.Semaphore(max_concurrent)
    results = []

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)

        async def one(url):
            async with sem:
                context = await browser.new_context()
                page = await context.new_page()
                try:
                    await page.goto(url, wait_until="domcontentloaded")
                    title = await page.title()
                    body = await page.inner_text("body")
                    results.append((url, title, len(body)))
                except Exception as exc:  # noqa: BLE001
                    results.append((url, f"ERROR: {exc}", 0))
                finally:
                    await context.close()

        await asyncio.gather(*(one(u) for u in urls))
        await browser.close()

    return results


if __name__ == "__main__":
    print(__doc__)
