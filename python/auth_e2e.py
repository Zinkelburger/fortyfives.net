"""Sign up, sign out and sign in again with a password, through Turnstile.

    python python/auth_e2e.py --url http://localhost:4000

With Turnstile on it needs Cloudflare's always-pass testing keys (the dev
config), which headless Chrome solves without a challenge; production's real
widget shows a script-driven browser an interactive challenge. Each run
creates an account, so against production pass --email-domain
simulator.amazonses.com (SES's mailbox simulator) and delete it afterwards.
"""
import argparse
import secrets
import sys
import time

from selenium.webdriver.common.by import By

from tbot import get_driver


def wait_for(fn, what, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def page_text(d):
    return d.find_element(By.TAG_NAME, "body").text


def fill(d, name, value):
    field = d.find_element(By.NAME, name)
    field.clear()
    field.send_keys(value)


def token_ready(d):
    """True once the Turnstile token is in the form, or if there is no widget."""
    return d.execute_script(
        "if (!document.querySelector('.cf-turnstile')) return 'no widget';"
        "return (document.querySelector('[name=cf-turnstile-response]') || {}).value")


def submit(d, label):
    d.find_element(By.XPATH, f"//form//button[contains(., '{label}')]").click()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="http://localhost:4000")
    parser.add_argument("--email-domain", default="example.com")
    args = parser.parse_args()
    base = args.url.rstrip("/")

    username = "e2e_" + secrets.token_hex(4)
    password = secrets.token_urlsafe(16)
    d = get_driver()
    try:
        d.get(f"{base}/users/register")
        fill(d, "user[username]", username)
        fill(d, "user[email]", f"{username}@{args.email_domain}")
        print(f"account: {username}")
        fill(d, "user[password]", password)
        wait_for(lambda: token_ready(d), "Turnstile token on /users/register")
        submit(d, "Create an account")
        wait_for(lambda: "Account created" in page_text(d), "registration")
        print("PASS  registration signed the new account in")

        d.find_element(By.LINK_TEXT, "Log out").click()
        wait_for(lambda: "Log in" in page_text(d), "sign-out")

        # A wrong password must reach the password check, which proves the
        # Turnstile token was posted with the form.
        for attempt, expected in ((password + "x", "Invalid username or password"),
                                  (password, "Welcome back!")):
            d.get(f"{base}/users/log_in")
            fill(d, "user[username_or_email]", username)
            fill(d, "user[password]", attempt)
            wait_for(lambda: token_ready(d), "Turnstile token on /users/log_in")
            submit(d, "Sign in")
            wait_for(lambda: expected in page_text(d) or "verification challenge" in page_text(d),
                     f"sign-in answer ({expected})")
            text = page_text(d)
            if expected not in text:
                raise AssertionError(f"expected {expected!r}, page said: {text[:300]!r}")
            print(f"PASS  password sign-in: {expected}")
    except Exception as exc:
        print(f"FAIL  {exc}")
        d.save_screenshot("auth_e2e_failure.png")
        sys.exit(1)
    finally:
        d.quit()


if __name__ == "__main__":
    main()
