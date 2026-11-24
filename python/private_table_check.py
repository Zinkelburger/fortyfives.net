"""Drives a private table the way a group on phones does, in real browsers.

Each player is a separate Chrome with its own cookies. "Switching apps" is
the page's socket closing under it, which is what a phone does to a
backgrounded browser within seconds.

  1. The creator makes a table and is seated without tapping Join.
  2. The creator switches apps to send the link: the seat is kept, shown as
     away to a friend who opens the link and joins.
  3. The creator comes back and still has the seat.
  4. A third player taps "Add a bot" without joining first: they are seated
     and the bot fills the table, so the game starts with all three in it.
  5. A second table fills while its creator is away; reopening the link
     takes the creator straight into the game.

Usage: CHROMEDRIVER=... python python/private_table_check.py --url http://localhost:4010
"""
import argparse
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait

PHONE = (390, 844)
TIMEOUT = 15


def browser() -> webdriver.Chrome:
    options = Options()
    for arg in ("--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage"):
        options.add_argument(arg)
    options.add_argument(f"--window-size={PHONE[0]},{PHONE[1]}")
    path = os.getenv("CHROMEDRIVER")
    driver = webdriver.Chrome(service=Service(path), options=options) if path else webdriver.Chrome(options=options)
    driver.set_page_load_timeout(30)
    return driver


def until(driver, condition, what):
    try:
        return WebDriverWait(driver, TIMEOUT).until(condition)
    except Exception:
        raise AssertionError(f"timed out waiting for: {what} (at {driver.current_url})") from None


def connected(driver):
    until(
        driver,
        lambda d: d.execute_script(
            "const m = document.querySelector('[data-phx-main]');"
            "return !!m && m.classList.contains('phx-connected')"
        ),
        "the page to connect",
    )


def present(driver, selector):
    return len(driver.find_elements(By.CSS_SELECTOR, selector)) > 0


def cards(driver):
    return [
        (card.find_element(By.CSS_SELECTOR, "p").text, "player-card-away" in card.get_attribute("class"))
        for card in driver.find_elements(By.CSS_SELECTOR, ".player-card")
    ]


def seats(driver):
    return driver.find_element(By.CSS_SELECTOR, "#add-bot-button .bot-seat-count").text


def tap(driver, selector):
    until(driver, lambda d: present(d, selector), selector)
    driver.find_element(By.CSS_SELECTOR, selector).click()


def create_table(driver, url):
    driver.get(f"{url}/play?tab=private")
    connected(driver)
    tap(driver, "#create-private-button")
    until(driver, lambda d: "/play/private/" in d.current_url, "the new table's page")
    connected(driver)
    # The link shows the site's public address; follow it on the server under test.
    return url + urlparse(driver.find_element(By.ID, "share_link").text.strip()).path


def switch_apps(driver):
    driver.execute_script("window.liveSocket.disconnect()")


def come_back(driver):
    driver.execute_script("window.liveSocket.connect()")
    connected(driver)


def in_game(driver):
    until(driver, lambda d: "/game/" in d.current_url, "the game to start")
    return driver.current_url.rsplit("/", 1)[-1]


def check(step, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {step}{' — ' + detail if detail else ''}")
    if not ok:
        raise AssertionError(step)


def run(url: str, out: Path):
    out.mkdir(parents=True, exist_ok=True)
    drivers = []

    def player():
        drivers.append(browser())
        return drivers[-1]

    try:
        # Table 1
        creator, friend, third = player(), player(), player()

        link = create_table(creator, url)
        until(creator, lambda d: present(d, "#leave-queue-button"), "the creator's seat")
        check("creator is seated on creating the table", cards(creator) == [("Anonymous", False)], str(cards(creator)))
        creator.save_screenshot(str(out / "1-created.png"))

        switch_apps(creator)
        friend.get(link)
        connected(friend)
        until(friend, lambda d: cards(d) == [("Anonymous", True)], "the creator shown as away")
        check("creator's seat is kept while they send the link", seats(friend) == "1/4", seats(friend))
        friend.save_screenshot(str(out / "2-friend-sees-away.png"))

        tap(friend, "#join-queue-button")
        until(friend, lambda d: seats(d) == "2/4", "the friend's seat")

        come_back(creator)
        until(creator, lambda d: present(d, "#leave-queue-button"), "the creator's seat after coming back")
        until(friend, lambda d: all(not away for _name, away in cards(d)), "the away mark to clear")
        check("creator still has the seat after coming back", seats(creator) == "2/4", seats(creator))
        creator.save_screenshot(str(out / "3-creator-back.png"))

        third.get(link)
        connected(third)
        check("a player who has not joined sees Join and Add a bot", present(third, "#join-queue-button"))
        tap(third, "#add-bot-button")

        games = {in_game(d) for d in (creator, friend, third)}
        check("Add a bot seated its player and the game has all three", len(games) == 1, str(games))
        third.save_screenshot(str(out / "4-game.png"))

        # Table 2: fills while its creator is away.
        creator2, friend2 = player(), player()
        link2 = create_table(creator2, url)
        until(creator2, lambda d: present(d, "#leave-queue-button"), "the second creator's seat")
        switch_apps(creator2)

        friend2.get(link2)
        connected(friend2)
        tap(friend2, "#join-queue-button")
        until(friend2, lambda d: seats(d) == "2/4", "the friend's seat")
        tap(friend2, "#add-bot-button")
        until(friend2, lambda d: "/game/" in d.current_url or seats(d) == "3/4", "the first bot")
        tap(friend2, "#add-bot-button")
        game = in_game(friend2)

        creator2.get(link2)
        check("reopening the link of a started table lands in the game", in_game(creator2) == game, creator2.current_url)
        creator2.save_screenshot(str(out / "5-creator-lands-in-game.png"))
    finally:
        for driver in drivers:
            driver.quit()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:4000")
    parser.add_argument("--out", type=Path, default=Path("artifacts/private-table"))
    args = parser.parse_args()

    try:
        run(args.url.rstrip("/"), args.out)
    except AssertionError as error:
        print(f"private table check failed: {error}")
        sys.exit(1)

    print("private table check passed")
