"""Screenshot key pages and check layout invariants.

    python python/ui_check.py --url http://localhost:4000 --out shots/new --check

Screenshots every page in PAGES at a desktop and a phone width (full page,
animations off, the Turnstile widget hidden) into --out, so two builds can be
compared with ui_diff.py. With --check it also asserts the invariants below
and exits non-zero when one fails; those catch regressions like a header
logo that silently grew to 440px or queue buttons drifting apart in size.

When a check fails because the design changed on purpose, update the
expected value here in the same commit.
"""

import argparse
import sys
import time
from pathlib import Path

from selenium.webdriver.common.by import By

from tbot import get_driver, live_socket_connected

VIEWPORTS = {"desktop": (1400, 900), "phone": (390, 844)}

# name -> path; "play-joined" joins the public queue first.
PAGES = {
    "home": "/",
    "learn": "/learn",
    "play": "/play",
    "play-joined": "/play",
    "play-private": "/play?tab=private",
    "log-in": "/users/log_in",
    "register": "/users/register",
    "reset-password": "/users/reset_password",
}

# Layout invariants (CSS pixels).
MAX_HEADER_HEIGHT = 160
LOGO_WIDTH_RANGE = (100, 180)

# Action button colours (computed background-color). The large bold labels
# keep these brighter shades on purpose; see the palette note in app.css.
EXPECTED_BUTTON_COLORS = {
    "#join-queue-button": "rgb(94, 144, 90)",
    "#leave-queue-button": "rgb(212, 4, 34)",
    "#add-bot-button": "rgb(37, 99, 235)",
}

FREEZE_CSS = """
*, *::before, *::after {
  animation: none !important;
  transition: none !important;
  caret-color: transparent !important;
}
[id$="-turnstile"], iframe { visibility: hidden !important; }
"""


class UiCheck:
    def __init__(self, base_url: str, out_dir: Path, check: bool) -> None:
        self.base_url = base_url.rstrip("/")
        self.out_dir = out_dir
        self.check = check
        self.failures: list[str] = []

    def fail(self, where: str, message: str) -> None:
        self.failures.append(f"{where}: {message}")
        print(f"FAIL {where}: {message}", flush=True)

    def js(self, driver, script: str, *args):
        return driver.execute_script(script, *args)

    def settle(self, driver) -> None:
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                if live_socket_connected(driver) or not self.js(
                    driver, "return !!document.querySelector('[data-phx-main]')"
                ):
                    break
            except Exception:
                pass
            time.sleep(0.25)
        self.js(
            driver,
            """
            const style = document.createElement('style');
            style.textContent = arguments[0];
            document.head.appendChild(style);
            """,
            FREEZE_CSS,
        )
        driver.execute_async_script(
            "const done = arguments[0]; document.fonts.ready.then(() => done());"
        )
        time.sleep(0.5)

    def set_viewport(self, driver, width: int, height: int) -> None:
        # Emulate the viewport instead of resizing the window: headless
        # Chrome won't make a window narrower than ~500px, which would
        # quietly turn the phone checks into small-tablet checks.
        driver.execute_cdp_cmd(
            "Emulation.setDeviceMetricsOverride",
            {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width < 600},
        )

    def screenshot(self, driver, name: str, width: int, height: int) -> None:
        full = self.js(driver, "return document.documentElement.scrollHeight")
        self.set_viewport(driver, width, max(height, min(full, 6000)))
        time.sleep(0.3)
        path = self.out_dir / f"{name}.png"
        driver.save_screenshot(str(path))
        self.set_viewport(driver, width, height)

    # ── Invariants ──────────────────────────────────────────────────

    def check_layout(self, driver, where: str, viewport: str) -> None:
        header = self.js(
            driver,
            """
            const h = document.querySelector('.site-header');
            const logo = document.querySelector('.site-logo');
            return {
              header: h && h.getBoundingClientRect().height,
              logo: logo && logo.getBoundingClientRect().width,
              scrollWidth: document.documentElement.scrollWidth,
              innerWidth: window.innerWidth,
            };
            """,
        )
        if header["header"] is not None and header["header"] > MAX_HEADER_HEIGHT:
            self.fail(where, f"header is {header['header']:.0f}px tall (max {MAX_HEADER_HEIGHT})")
        if header["logo"] is not None:
            low, high = LOGO_WIDTH_RANGE
            if not low <= header["logo"] <= high:
                self.fail(where, f"logo is {header['logo']:.0f}px wide (expected {low}-{high})")
        if header["scrollWidth"] > header["innerWidth"] + 1:
            self.fail(
                where,
                f"page scrolls sideways ({header['scrollWidth']}px content in "
                f"a {header['innerWidth']}px {viewport} viewport)",
            )

    def check_queue_buttons(self, driver, where: str) -> None:
        buttons = self.js(
            driver,
            """
            return [...document.querySelectorAll('.queue-actions > button')]
              .filter(b => b.offsetParent !== null)
              .map(b => {
                const cs = getComputedStyle(b);
                return {
                  label: b.innerText.replace(/\\s+/g, ' ').trim(),
                  fontSize: cs.fontSize,
                  fontWeight: cs.fontWeight,
                  height: Math.round(b.getBoundingClientRect().height),
                };
              });
            """,
        )
        if len(buttons) < 2:
            self.fail(where, f"expected at least 2 queue buttons, found {len(buttons)}")
            return
        first = buttons[0]
        for other in buttons[1:]:
            for key in ("fontSize", "fontWeight"):
                if other[key] != first[key]:
                    self.fail(
                        where,
                        f"'{other['label']}' {key} {other[key]} differs from "
                        f"'{first['label']}' {first[key]}",
                    )
            if abs(other["height"] - first["height"]) > 2:
                self.fail(
                    where,
                    f"'{other['label']}' is {other['height']}px tall, "
                    f"'{first['label']}' is {first['height']}px",
                )

    def check_colors(self, driver, where: str) -> None:
        for selector, expected in EXPECTED_BUTTON_COLORS.items():
            actual = self.js(
                driver,
                """
                const el = document.querySelector(arguments[0]);
                return el && getComputedStyle(el).backgroundColor;
                """,
                selector,
            )
            if actual is not None and actual != expected:
                self.fail(where, f"{selector} background is {actual}, expected {expected}")

    # ── Run ─────────────────────────────────────────────────────────

    def run(self) -> int:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        for viewport, (width, height) in VIEWPORTS.items():
            driver = get_driver()
            try:
                self.set_viewport(driver, width, height)
                for name, path in PAGES.items():
                    where = f"{name} @ {viewport}"
                    driver.delete_all_cookies()
                    driver.get(self.base_url + path)
                    self.settle(driver)
                    if name == "play-joined":
                        driver.find_element(By.ID, "join-queue-button").click()
                        deadline = time.time() + 10
                        while not driver.find_elements(By.ID, "leave-queue-button"):
                            if time.time() > deadline:
                                self.fail(where, "joining the queue never showed Leave Queue")
                                break
                            time.sleep(0.25)
                        time.sleep(0.5)
                    if self.check:
                        self.check_layout(driver, where, viewport)
                        if name in ("play", "play-joined"):
                            self.check_queue_buttons(driver, where)
                            self.check_colors(driver, where)
                    self.screenshot(driver, f"{viewport}-{name}", width, height)
                    if name == "play-joined":
                        # Free the seat so the next page starts from an empty queue.
                        for button in driver.find_elements(By.ID, "leave-queue-button"):
                            button.click()
                        time.sleep(0.5)
                    print(f"ok   {where}", flush=True)
            finally:
                driver.quit()

        if self.failures:
            print(f"\n{len(self.failures)} UI check(s) failed:", flush=True)
            for failure in self.failures:
                print(f"  - {failure}", flush=True)
            return 1
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="http://localhost:4000")
    parser.add_argument("--out", default="artifacts/ui/new", type=Path)
    parser.add_argument("--check", action="store_true", help="assert layout invariants")
    args = parser.parse_args()
    sys.exit(UiCheck(args.url, args.out, args.check).run())


if __name__ == "__main__":
    main()
