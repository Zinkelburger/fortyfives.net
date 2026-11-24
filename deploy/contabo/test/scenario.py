#!/usr/bin/env python3
"""Blue/green deploy rehearsal; run by run.sh, which sets up the project.

Round 1, blue -> green: one player sits in a game, one in the public queue
with a bot, one in a private lobby with a bot, one on the home page. After
`slots.sh switch` the game must stay on blue and everyone else must be on
green, still seated where they were. The game ends, blue drains and is
retired.

Round 2, green -> blue and straight back (a rollback while blue still runs).

A watcher requests / ten times a second throughout; any answer but 200 fails.
"""
import argparse
import os
import subprocess
import sys
import threading
import time

from playwright.sync_api import sync_playwright

SITE = "https://fortyfives.net"

failures = []


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


def eventually(fn, what, timeout=30):
    """Polls fn until it returns True; anything else is what it saw."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = fn()
            if last is True:
                return check(True, what)
        except Exception as e:  # page navigating, element gone, ...
            last = e
        time.sleep(0.5)
    return check(False, f"{what} (saw: {last!r})")


class Rehearsal:
    def __init__(self, args):
        self.dir = args.dir
        self.port = args.port
        self.image_a = args.image_a
        self.image_b = args.image_b
        self.codes = []
        self.watching = False

    # --- host side ---------------------------------------------------------

    def slots(self, *argv, ok_codes=(0,)):
        print(f"$ slots.sh {' '.join(argv)}", flush=True)
        p = subprocess.run(["bash", "slots.sh", *argv], cwd=self.dir, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print("    " + p.stdout.strip().replace("\n", "\n    "), flush=True)
        if p.returncode not in ok_codes:
            raise SystemExit(f"slots.sh {argv[0]} exited {p.returncode}")
        return p.stdout

    def curl(self, path, *extra):
        p = subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-D", "-", "--max-time", "5",
             "--connect-to", f"fortyfives.net:443:127.0.0.1:{self.port}", *extra, SITE + path],
            text=True, stdout=subprocess.PIPE)
        return p.stdout

    def slot_by_header(self, slot):
        headers = self.curl("/healthz", "-H", f"X-FF-Slot: {slot}").lower()
        return f"x-ff-slot: {slot}" in headers

    def watch(self):
        self.watching = True

        def loop():
            while self.watching:
                out = self.curl("/")
                code = out.split(" ", 2)[1] if out.startswith("HTTP/") else "none"
                self.codes.append(code)
                time.sleep(0.1)

        t = threading.Thread(target=loop, daemon=True)
        t.start()
        return t

    # --- browser side ------------------------------------------------------

    def open(self, browser, path):
        ctx = browser.new_context(ignore_https_errors=True)
        page = ctx.new_page()
        page.on("dialog", lambda d: d.accept())
        page.goto(SITE + path)
        self.connected(page)
        return page

    @staticmethod
    def connected(page):
        page.wait_for_selector("[data-phx-main].phx-connected", timeout=20000)

    @staticmethod
    def slot(page):
        return page.evaluate(
            "fetch('/healthz', {cache: 'no-store'}).then(r => r.headers.get('x-ff-slot'))")

    @staticmethod
    def mark(page):
        page.evaluate("window.__ffMark = true")

    @staticmethod
    def reloaded(page):
        return page.evaluate("window.__ffMark === undefined")

    @staticmethod
    def cards(page):
        return page.locator(".player-card").count()

    def add_bot(self, page, expect_cards):
        page.click("#add-bot-button")
        eventually(lambda: self.cards(page) >= expect_cards or self.cards(page), f"bot seated ({expect_cards} at the table)", 10)

    def lands(self, page, slot, path, text=None, cards=None, label=""):
        def there():
            seen = {"reloaded": self.reloaded(page), "url": page.url[len(SITE):]}
            if not seen["reloaded"] or seen["url"] != path:
                return seen
            self.connected(page)
            seen["text"] = not text or text in page.content()
            seen["cards"] = self.cards(page)
            seen["slot"] = self.slot(page)
            ok = seen["text"] and (cards is None or seen["cards"] == cards) and seen["slot"] == slot
            return True if ok else seen
        detail = ", ".join(x for x in [text, cards is not None and f"{cards} at the table"] if x)
        eventually(there, f"{label}: reloaded onto {slot} at {path}" + (f" ({detail})" if detail else ""))

    # --- rounds ------------------------------------------------------------

    def run(self):
        self.slots("state")
        watcher = self.watch()
        with sync_playwright() as pw:
            browser = pw.chromium.launch(
                args=[f"--host-resolver-rules=MAP fortyfives.net 127.0.0.1:{self.port}"])
            self.round_one(browser)
            self.round_two(browser)
            browser.close()
        self.watching = False
        watcher.join()
        bad = [c for c in self.codes if c != "200"]
        check(not bad and len(self.codes) > 100,
              f"{len(self.codes)} requests to / during the rehearsal, {len(bad)} not 200 {sorted(set(bad))}")

    def round_one(self, browser):
        print("\n== Round 1: blue -> green, with a game on blue", flush=True)
        game = self.open(browser, "/play?tab=private")
        game.click("#create-private-button")
        game.wait_for_url("**/play/private/**")
        self.connected(game)
        eventually(lambda: "You are in the game lobby" in game.content(), "creator seated on creating the table")
        for n in (2, 3):
            self.add_bot(game, n)
        game.click("#add-bot-button")
        game.wait_for_url("**/game/**", timeout=20000)
        game.wait_for_selector("#game-container")
        game_path = game.url[len(SITE):]
        check(True, f"game started at {game_path}")

        queue = self.open(browser, "/play")
        queue.click("#join-queue-button")
        eventually(lambda: "You are in the queue" in queue.content(), "public queue joined")
        self.add_bot(queue, 2)

        lobby = self.open(browser, "/play?tab=private")
        lobby.click("#create-private-button")
        lobby.wait_for_url("**/play/private/**")
        self.connected(lobby)
        lobby_path = lobby.url[len(SITE):]
        eventually(lambda: "You are in the game lobby" in lobby.content(), "creator seated on creating the table")
        self.add_bot(lobby, 2)

        home = self.open(browser, "/")
        for name, page in [("game", game), ("queue", queue), ("lobby", lobby), ("home", home)]:
            check(self.slot(page) == "blue", f"{name} is on blue")
            self.mark(page)

        self.slots("start", self.image_b)
        check(self.slot_by_header("green"), "X-FF-Slot: green reaches the new slot before the switch")
        check(self.slot(home) == "blue", "visitors still go to blue before the switch")
        self.slots("switch")

        self.lands(home, "green", "/", label="home")
        self.lands(queue, "green", "/play", "You are in the queue", 2, label="queue")
        self.lands(lobby, "green", lobby_path, "You are in the game lobby", 2, label="lobby")
        check(not self.reloaded(game) and self.slot(game) == "blue", "game: not reloaded, still on blue")
        game.reload()
        game.wait_for_selector("#game-container", timeout=20000)
        check(self.slot(game) == "blue", "game: a reload keeps the table on blue")
        newcomer = self.open(browser, "/")
        check(self.slot(newcomer) == "green", "a new visitor gets green")

        out = self.slots("retire", ok_codes=(1,))
        check("game(s)" in out, "retire refuses while blue has a game")

        # The seated player leaves the game from blue's lobby page.
        game.goto(SITE + "/play")
        self.connected(game)
        check(self.slot(game) == "blue", "seated player's lobby page is served by blue")
        game.click("#abandon-game-button")
        eventually(lambda: "You left your game." in game.content(), "game abandoned")
        game.goto(SITE + "/")
        self.connected(game)
        check(self.slot(game) == "green", "after the game, the player's next page is on green")

        self.slots("wait", "2")
        self.slots("retire")
        out = self.slots("state")
        check("live=green draining=-" in out and "blue: stopped" in out, "green live, blue stopped")
        for name, page in [("queue", queue), ("lobby", lobby)]:
            check(self.slot(page) == "green", f"{name} still on green after blue stopped")
        check("You are in the queue" in queue.content(), "queue: still seated after blue stopped")
        for page in (game, queue, lobby, home, newcomer):
            page.context.close()

    def round_two(self, browser):
        print("\n== Round 2: green -> blue, then back to green while blue still runs", flush=True)
        home = self.open(browser, "/")
        queue = self.open(browser, "/play")
        queue.click("#join-queue-button")
        eventually(lambda: "You are in the queue" in queue.content(), "public queue joined on green")
        for page in (home, queue):
            self.mark(page)

        # blue stopped seconds ago, so nginx may still hold its old address.
        self.slots("start", self.image_a)
        check(self.slot_by_header("blue"), "X-FF-Slot: blue reaches the restarted slot before the switch")
        self.slots("switch")
        self.lands(home, "blue", "/", label="home")
        self.lands(queue, "blue", "/play", "You are in the queue", label="queue")

        for page in (home, queue):
            self.mark(page)
        self.slots("switch")  # the rollback
        self.lands(home, "green", "/", label="home after the rollback")
        self.lands(queue, "green", "/play", "You are in the queue", label="queue after the rollback")
        self.slots("retire")
        out = self.slots("state")
        check("live=green draining=-" in out and "blue: stopped" in out, "green live, blue stopped")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", required=True)
    ap.add_argument("--image-a", required=True)
    ap.add_argument("--image-b", required=True)
    args = ap.parse_args()
    os.environ.setdefault("COMPOSE", "docker compose")
    Rehearsal(args).run()
    print()
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
