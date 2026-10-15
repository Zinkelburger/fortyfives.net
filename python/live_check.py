"""Check that sign-in works on the live site.

    python python/live_check.py --url https://fortyfives.net --out artifacts/live

Read-only: creates no accounts and submits no forms. Checks
  * /healthz and /healthz/auth (Turnstile secret, real Turnstile
    verifications, Google OAuth client id and secret; see AuthHealth),
  * that /auth/google sends visitors to a Google sign-in page rather than
    Google's error page,
  * that the Turnstile widget loads on every auth form. A script-driven
    browser gets Cloudflare's interactive challenge, so the widget reaching
    that point is the pass; a wrong site key or domain reports an error code.

Exits non-zero if any check fails, and writes a table to $GITHUB_STEP_SUMMARY
when set.

Cloudflare challenges datacenter IPs such as GitHub's runners. When
LIVE_CHECK_TOKEN is set it is sent as the X-Live-Check header, which a
Cloudflare custom rule lets past the bot checks (see docs/deploy.md).
"""
import argparse
import base64
import os
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import requests
from selenium.webdriver.common.by import By

from tbot import get_driver

TURNSTILE_FORMS = ["/users/log_in", "/users/register", "/users/reset_password"]
BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) fortyfives-live-check"
LIVE_CHECK_TOKEN = os.getenv("LIVE_CHECK_TOKEN", "")
# Only for requests to the site itself; never sent to Google.
SITE_HEADERS = {"X-Live-Check": LIVE_CHECK_TOKEN} if LIVE_CHECK_TOKEN else {}


def check_healthz(base):
    r = requests.get(f"{base}/healthz", timeout=15, headers=SITE_HEADERS)
    return r.status_code == 200 and r.text == "ok", f"{r.status_code} {r.text[:60]}"


def check_auth_health(base):
    r = requests.get(f"{base}/healthz/auth", timeout=30, headers=SITE_HEADERS)
    try:
        body = r.json()
    except ValueError:
        return False, f"{r.status_code}, not JSON"
    checks = body.get("checks", {})
    detail = ", ".join(f"{name} {result}" for name, result in sorted(checks.items()))
    return r.status_code == 200 and body.get("status") == "ok", detail


def check_google_redirect(base):
    r = requests.get(f"{base}/auth/google", allow_redirects=False, timeout=15,
                     headers={"User-Agent": BROWSER_UA, **SITE_HEADERS})
    location = r.headers.get("location", "")
    target = urlparse(location)
    if r.status_code != 302 or target.hostname != "accounts.google.com":
        return False, f"/auth/google answered {r.status_code} to {target.hostname}"

    query = parse_qs(target.query)
    redirect_uri = query.get("redirect_uri", [""])[0]
    if redirect_uri != f"{base}/auth/google/callback":
        return False, f"redirect_uri is {redirect_uri!r}"
    if not query.get("client_id", [""])[0]:
        return False, "no client_id"

    # Google answers a bad client or redirect URI with a redirect to its
    # error page; a good request goes on to the account chooser.
    g = requests.get(location, allow_redirects=False, timeout=15,
                     headers={"User-Agent": BROWSER_UA})
    next_url = g.headers.get("location", "")
    if "/signin/oauth/error" in next_url:
        return False, f"Google error page: {google_auth_error(next_url)}"
    if g.status_code not in (200, 302):
        return False, f"Google answered {g.status_code}"
    return True, "Google sign-in page"


def google_auth_error(url):
    """authError is base64 protobuf; its readable strings are enough."""
    raw = parse_qs(urlparse(url).query).get("authError", [""])[0]
    try:
        decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    except ValueError:
        return raw[:80]
    text = "".join(chr(b) if 32 <= b < 127 else "\0" for b in decoded)
    return " / ".join(part for part in text.split("\0") if len(part) > 2)[:160]


def check_turnstile(driver, base, path, out):
    driver.get(f"{base}{path}")
    deadline = time.time() + 30
    state = None
    while time.time() < deadline:
        widgets = driver.find_elements(By.CSS_SELECTOR, ".cf-turnstile")
        if not widgets:
            state = "no widget on the page"
        else:
            state = widgets[0].get_attribute("data-turnstile-state")
            if state in ("interactive", "solved"):
                return True, state
            if state and state != "rendered":
                break
        time.sleep(0.5)
    if out:
        driver.save_screenshot(str(out / f"turnstile{path.replace('/', '_')}.png"))
    return False, state or "widget never rendered"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="https://fortyfives.net")
    parser.add_argument("--out", type=Path, help="screenshots of failing widgets")
    parser.add_argument("--skip-browser", action="store_true")
    args = parser.parse_args()
    base = args.url.rstrip("/")
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)

    results = []

    def run(name, fn, *fn_args):
        try:
            ok, detail = fn(*fn_args)
        except Exception as exc:  # a crashed check is a failed check
            ok, detail = False, f"{type(exc).__name__}: {exc}"
        results.append((name, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)

    run("healthz", check_healthz, base)
    run("healthz/auth", check_auth_health, base)
    run("Google sign-in redirect", check_google_redirect, base)

    if not args.skip_browser:
        driver = get_driver()
        if SITE_HEADERS:
            # Sent with every request the page makes; it loads only this site
            # and challenges.cloudflare.com.
            driver.execute_cdp_cmd("Network.enable", {})
            driver.execute_cdp_cmd("Network.setExtraHTTPHeaders", {"headers": SITE_HEADERS})
        try:
            for path in TURNSTILE_FORMS:
                run(f"Turnstile on {path}", check_turnstile, driver, base, path, args.out)
        finally:
            driver.quit()

    summary = os.getenv("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"## Live sign-in check: {base}\n\n| Check | Result | Detail |\n|---|---|---|\n")
            for name, ok, detail in results:
                f.write(f"| {name} | {'pass' if ok else '**FAIL**'} | {detail} |\n")

    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
