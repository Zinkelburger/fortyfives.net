"""Selenium player bot for the end-to-end CI run.

Each process drives one headless Chrome through a full game. TBOT_SCENARIO
picks how it gets into a game and what it checks along the way:

  public         join the public queue and play to Final Scoring (default)
  private-host   create a private lobby, publish its URL to TBOT_LOBBY_FILE,
                 wait for TBOT_WAIT_FOR_PLAYERS players, fill the rest with
                 server bots and play to Final Scoring
  private-guest  join the lobby from TBOT_LOBBY_FILE and play to Final
                 Scoring; with TBOT_REJOIN=1, leave for the lobby after the
                 first card and come back through "Rejoin Game"
  abandon        create a private lobby, fill it with bots, play one card,
                 then abandon from the lobby and check the seat is released
"""

import json
import os
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit

from bs4 import BeautifulSoup
from card import Suit, Card, less_than, is_ace_of_hearts
from selenium import webdriver
from selenium.common.exceptions import TimeoutException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

ACTION_TIMEOUT = 20
# How long to wait for the server to acknowledge a click before sending it
# again. A click can be lost if it lands while LiveView is still wiring up
# the page; that single lost Join click failed a whole CI run once.
CLICK_ACK_TIMEOUT = 5
CLICK_ATTEMPTS = 4
JOIN_TIMEOUT = 120
MATCH_TIMEOUT = 180
PHASE_TIMEOUT = 180
POLL_INTERVAL = 0.5
TOTAL_RUNTIME_TIMEOUT = 900


def get_driver() -> webdriver.Chrome:
    chrome_options = Options()
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")
    chrome_options.add_argument("--headless=new")

    # Without an explicit driver, Selenium Manager finds (or fetches) the
    # chromedriver that matches the installed Chrome.
    chromedriver_path = os.getenv("CHROMEDRIVER")
    if chromedriver_path:
        service = Service(executable_path=chromedriver_path)
        return webdriver.Chrome(service=service, options=chrome_options)

    return webdriver.Chrome(options=chrome_options)


def live_socket_connected(driver: webdriver.Chrome) -> bool:
    return bool(
        driver.execute_script(
            """
            return Boolean(
                window.liveSocket &&
                typeof window.liveSocket.isConnected === "function" &&
                window.liveSocket.isConnected()
            )
            """
        )
    )


def evaluate_hand_bid(player_hand: list[Card]) -> tuple[int, Suit]:
    small_cards = {Suit.HEARTS: 0, Suit.DIAMONDS: 0, Suit.CLUBS: 0, Suit.SPADES: 0}
    sure_points = {Suit.HEARTS: 0, Suit.DIAMONDS: 0, Suit.CLUBS: 0, Suit.SPADES: 0}
    face_card_points = {5: 12, 11: 6, 1: 4, 13: 3, 12: 2}

    for card in player_hand:
        if is_ace_of_hearts(card):
            for key in sure_points:
                sure_points[key] += 5
        elif card.value in face_card_points:
            sure_points[card.suit] += face_card_points[card.value]
        else:
            small_cards[card.suit] += 1

    max_sure_suit = max(sure_points, key=sure_points.get)
    estimated_value = small_cards[max_sure_suit] * 3 + sure_points[max_sure_suit]

    if estimated_value >= 15:
        return int(estimated_value // 5) * 5, max_sure_suit
    else:
        return 0, max_sure_suit


def get_max_card(cards: list[Card], suit_led: Suit, trump: Suit) -> Optional[Card]:
    if len(cards) == 0:
        return None
    max_card = cards[0]
    for card in cards[1:]:
        if not less_than(card, max_card, suit_led, trump):
            max_card = card
    return max_card


def get_min_card(cards: list[Card], suit_led: Suit, trump: Suit) -> Optional[Card]:
    if len(cards) == 0:
        return None
    min_card = cards[0]
    for card in cards[1:]:
        if less_than(card, min_card, suit_led, trump):
            min_card = card
    return min_card


def evaluate_hand_play(
    suit_led: Suit,
    player_hand: list[Card],
    current_cards: list[Card],
    trump: Suit,
) -> Card:
    if not current_cards:
        max_card = None
    else:
        max_card = get_max_card(current_cards, suit_led, trump)

    players_max_card = get_max_card(player_hand, suit_led, trump)
    players_lowest_offsuite = get_min_card(
        [card for card in player_hand if card.suit != suit_led and card.suit != trump],
        suit_led,
        trump,
    )
    players_worst_trump = (
        get_min_card(
            [card for card in player_hand if card.suit == trump], suit_led, trump
        )
        if any(card.suit == trump for card in player_hand)
        else None
    )

    if not max_card:
        return players_max_card

    if not less_than(players_max_card, max_card, suit_led, trump):
        return players_max_card
    elif suit_led == trump and players_worst_trump:
        return players_worst_trump
    elif players_lowest_offsuite:
        return players_lowest_offsuite

    return player_hand[0]


class PhxWeb:
    def __init__(self, base_url: str) -> None:
        parts = urlsplit(base_url)
        self.origin = f"{parts.scheme}://{parts.netloc}"
        self.url = base_url
        self.driver = get_driver()
        self.instance = os.getenv("TBOT_INSTANCE", str(os.getpid()))
        self.scenario = os.getenv("TBOT_SCENARIO", "public")
        self.lobby_file = Path(os.getenv("TBOT_LOBBY_FILE", "artifacts/private_lobby_url"))
        self.wait_for_players = int(os.getenv("TBOT_WAIT_FOR_PLAYERS", "1"))
        self.rejoin_pending = os.getenv("TBOT_REJOIN") == "1"
        self.cards_played = 0
        self.finished = False

    def log(self, msg: str) -> None:
        print(f"[tbot {self.instance}] {msg}", flush=True)

    def snapshot(self) -> BeautifulSoup:
        return BeautifulSoup(self.driver.page_source, "html.parser")

    def get_phase(self, soup: BeautifulSoup) -> str:
        container = soup.find(id="game-container")
        if container:
            return container.get("data-phase", "")
        return ""

    def is_my_turn(self, soup: BeautifulSoup) -> bool:
        container = soup.find(id="game-container")
        if container:
            return container.get("data-current-turn") == "true"
        return False

    def is_auto_playing(self, soup: BeautifulSoup) -> bool:
        container = soup.find(id="game-container")
        if container:
            return container.get("data-auto-playing") == "true"
        return False

    def is_bagged(self, soup: BeautifulSoup) -> bool:
        container = soup.find(id="game-container")
        if container:
            return container.get("data-bagged") == "true"
        return False

    def get_max_bid(self, soup: BeautifulSoup) -> int:
        container = soup.find(id="game-container")
        if container:
            return int(container.get("data-current-bid", "0"))
        return 0

    def get_trump(self, soup: BeautifulSoup) -> Optional[Suit]:
        container = soup.find(id="game-container")
        if container:
            raw = (container.get("data-trump") or "").strip()
            if raw and raw not in ("", "nil", "none"):
                return Suit[raw.upper()]
        return None

    def get_suit_led(self, soup: BeautifulSoup) -> Optional[Suit]:
        container = soup.find(id="game-container")
        if container:
            raw = (container.get("data-suit-led") or "").strip()
            if raw and raw not in ("", "nil", "none"):
                return Suit[raw.upper()]
        return None

    def has_confirmed_discard(self, soup: BeautifulSoup) -> bool:
        container = soup.find(id="game-container")
        if container:
            return container.get("data-confirm-discard-clicked") == "true"
        return False

    def live_socket_connected(self) -> bool:
        return live_socket_connected(self.driver)

    def wait_until(self, predicate, timeout: int, description: str) -> None:
        deadline = time.time() + timeout
        last_exc = None
        while time.time() < deadline:
            try:
                if predicate():
                    return
            except Exception as exc:
                last_exc = exc
            time.sleep(POLL_INTERVAL)
        msg = f"Timed out: {description}"
        if last_exc is not None:
            msg += f" (last error: {type(last_exc).__name__}: {last_exc})"
        raise TimeoutException(msg)

    # ── Lobby: join a queue and wait for the game ─────────────────────

    def open_lobby(self, url: str) -> None:
        self.driver.get(url)
        self.wait_for_lobby()

    def wait_for_lobby(self) -> None:
        WebDriverWait(self.driver, JOIN_TIMEOUT).until(
            EC.presence_of_element_located((By.ID, "queue-root"))
        )
        self.wait_until(self.live_socket_connected, ACTION_TIMEOUT, "LiveView connection")
        self.log(f"Lobby LiveView is connected at {self.driver.current_url}.")

    def in_game(self) -> bool:
        return "/game/" in self.driver.current_url

    def click_until(
        self,
        element_id: str,
        acknowledged,
        description: str,
        ack_timeout: float = CLICK_ACK_TIMEOUT,
    ) -> None:
        """Click `element_id` until `acknowledged()` holds.

        Only safe for events the server treats as idempotent (join, fill
        bots, resume). The button may vanish once the first click lands, so
        its absence is not an error as long as the acknowledgement follows.
        """
        for attempt in range(1, CLICK_ATTEMPTS + 1):
            try:
                if acknowledged():
                    return
            except WebDriverException:
                pass
            buttons = self.driver.find_elements(By.ID, element_id)
            if buttons:
                try:
                    buttons[0].click()
                except WebDriverException as error:
                    self.log(f"Click on #{element_id} failed: {type(error).__name__}")
            try:
                self.wait_until(acknowledged, ack_timeout, description)
                return
            except TimeoutException:
                self.log(f"No {description} after click {attempt}/{CLICK_ATTEMPTS}; retrying.")
        self.wait_until(acknowledged, ACTION_TIMEOUT, description)

    def join_queue(self) -> None:
        self.click_until(
            "join-queue-button",
            lambda: self.in_game()
            or len(self.driver.find_elements(By.ID, "leave-queue-button")) == 1,
            "queue join acknowledgement",
        )
        self.log("Joined the queue.")

    def wait_for_game(self) -> None:
        self.wait_until(self.in_game, MATCH_TIMEOUT, "matchmaking redirect")
        self.wait_until(
            lambda: len(self.driver.find_elements(By.ID, "game-container")) == 1,
            ACTION_TIMEOUT,
            "game page load",
        )
        self.wait_until(self.live_socket_connected, ACTION_TIMEOUT, "game LiveView connection")
        self.url = self.driver.current_url
        self.log(f"Redirected to {self.url}")

    def create_private_lobby(self) -> None:
        # The "Play a Friend" tab has no #queue-root, only the create button.
        self.driver.get(f"{self.origin}/play?tab=private")
        WebDriverWait(self.driver, JOIN_TIMEOUT).until(
            EC.presence_of_element_located((By.ID, "create-private-button"))
        )
        self.wait_until(self.live_socket_connected, ACTION_TIMEOUT, "LiveView connection")
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((By.ID, "create-private-button"))
        ).click()
        self.wait_until(
            lambda: "/play/private/" in self.driver.current_url,
            ACTION_TIMEOUT,
            "private lobby navigation",
        )
        self.wait_for_lobby()
        self.log(f"Created private lobby {self.driver.current_url}")

    def publish_lobby_url(self) -> None:
        # Use the lobby's own URL: the rendered share link carries the
        # production host from the endpoint config.
        self.lobby_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.lobby_file.with_suffix(".tmp")
        tmp.write_text(self.driver.current_url, encoding="utf-8")
        tmp.replace(self.lobby_file)

    def read_lobby_url(self) -> str:
        self.wait_until(self.lobby_file.exists, JOIN_TIMEOUT, "private lobby URL from the host")
        return self.lobby_file.read_text(encoding="utf-8").strip()

    def player_cards(self) -> int:
        return len(self.driver.find_elements(By.CSS_SELECTOR, ".queue-cards .player-card"))

    def fill_with_bots(self) -> None:
        self.wait_until(
            lambda: self.in_game() or self.player_cards() >= self.wait_for_players,
            MATCH_TIMEOUT,
            f"{self.wait_for_players} players in the lobby",
        )
        self.log(f"{self.player_cards()} player(s) in the lobby; filling with bots.")
        # Each bot costs per-network budget, so give the redirect a full
        # action timeout before clicking again.
        self.click_until(
            "fill-bots-button",
            self.in_game,
            "game start after Fill with Bots",
            ack_timeout=ACTION_TIMEOUT,
        )

    def enter_game(self) -> None:
        if self.scenario == "public":
            self.open_lobby(self.url)
            self.join_queue()
        elif self.scenario in ("private-host", "abandon"):
            self.create_private_lobby()
            self.join_queue()
            if self.scenario == "private-host":
                self.publish_lobby_url()
            self.fill_with_bots()
        elif self.scenario == "private-guest":
            self.open_lobby(self.read_lobby_url())
            self.join_queue()
        else:
            raise RuntimeError(f"Unknown TBOT_SCENARIO: {self.scenario!r}")
        self.wait_for_game()

    # ── Mid-game detours: rejoin and abandon ────────────────────────

    def go_to_lobby_with_active_game(self) -> None:
        self.open_lobby(f"{self.origin}/play")
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.presence_of_element_located((By.ID, "rejoin-game-button"))
        )
        self.log("Lobby shows the game in progress.")

    def leave_and_rejoin(self) -> None:
        game_url = self.url
        self.go_to_lobby_with_active_game()
        # Stay away long enough for the game to register the departure.
        time.sleep(3)
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((By.ID, "rejoin-game-button"))
        ).click()
        self.wait_until(
            lambda: self.driver.current_url == game_url,
            ACTION_TIMEOUT,
            "navigation back to the game",
        )
        self.wait_until(
            lambda: len(self.driver.find_elements(By.ID, "game-container")) == 1,
            ACTION_TIMEOUT,
            "game page reload",
        )
        self.wait_until(self.live_socket_connected, ACTION_TIMEOUT, "game LiveView connection")
        self.log("Rejoined the game from the lobby.")

    def abandon_game(self) -> None:
        game_url = self.url
        self.go_to_lobby_with_active_game()
        # The Abandon button asks for confirmation through window.confirm.
        self.driver.execute_script("window.confirm = () => true;")
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((By.ID, "abandon-game-button"))
        ).click()
        self.wait_until(
            lambda: not self.driver.find_elements(By.ID, "rejoin-game-button")
            and len(self.driver.find_elements(By.ID, "join-queue-button")) == 1,
            ACTION_TIMEOUT,
            "lobby to release the abandoned seat",
        )
        self.log("Abandoned the game; the lobby offers Join Queue again.")

        # An abandoned seat can't be retaken: the game page sends us back.
        self.driver.get(game_url)
        self.wait_until(
            lambda: urlsplit(self.driver.current_url).path == "/play",
            ACTION_TIMEOUT,
            "redirect away from the abandoned game",
        )
        self.log("Abandon scenario complete: old game URL redirects to the lobby.")
        self.finished = True

    def after_card_played(self) -> None:
        self.cards_played += 1
        if self.rejoin_pending:
            self.rejoin_pending = False
            self.leave_and_rejoin()
        elif self.scenario == "abandon":
            self.abandon_game()

    # ── Snapshot-based hand extraction ──────────────────────────────

    def extract_hand(self, soup: BeautifulSoup, playable_only: bool = False) -> list[Card]:
        hand = []
        player_hand_div = soup.find(id="player-hand")
        if not player_hand_div:
            return hand
        for img in player_hand_div.find_all("img", class_="card"):
            if playable_only and "grayed-out" in (img.get("class") or []):
                continue
            card_value = img.get("data-card-value")
            if card_value:
                value, suit = card_value.split("_")
                hand.append(Card(value, Suit[suit.upper()]))
        return hand

    def extract_played_cards(self, soup: BeautifulSoup) -> list[Card]:
        cards = []
        table = soup.find(id="table")
        if not table:
            return cards
        for img in table.find_all("img"):
            card_value = img.get("phx-value-card")
            if card_value:
                value, suit = card_value.split("_")
                cards.append(Card(value, Suit[suit.upper()]))
        return cards

    # ── Auto-play recovery ──────────────────────────────────────────

    def resume_control_if_needed(self, soup: BeautifulSoup) -> bool:
        """If auto-playing, click resume and wait. Returns True if we resumed."""
        if not self.is_auto_playing(soup):
            return False

        buttons = self.driver.find_elements(By.ID, "resume-control-overlay")
        if not buttons:
            raise RuntimeError("Auto-play is on but resume button is missing.")

        self.click_until(
            "resume-control-overlay",
            lambda: not self.is_auto_playing(self.snapshot()),
            "manual control resume",
        )
        self.log("Resumed manual control.")
        return True

    # ── Card selection via Selenium click ───────────────────────────

    def selected_cards(self) -> list[str]:
        hand = self.driver.find_element(By.ID, "player-hand")
        raw = hand.get_attribute("data-selected-cards") or "[]"
        return json.loads(raw)

    def select_card(self, card: Card) -> None:
        card_value = f"{card.value}_{card.suit.long_name()}"
        if card_value in self.selected_cards():
            return

        selector = f"img[data-card-value='{card_value}']"
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
        ).click()

        self.wait_until(
            lambda: card_value in self.selected_cards(),
            ACTION_TIMEOUT,
            f"{card_value} selection",
        )
        self.log(f"Selected card {card_value}.")

    # ── Phase: Bidding ──────────────────────────────────────────────

    def bidding_phase(self) -> None:
        deadline = time.time() + PHASE_TIMEOUT

        while time.time() < deadline:
            soup = self.snapshot()
            phase = self.get_phase(soup)
            if phase != "Bidding":
                return

            if self.resume_control_if_needed(soup):
                continue

            if not self.is_my_turn(soup):
                time.sleep(POLL_INTERVAL)
                continue

            hand = self.extract_hand(soup)
            max_bid = self.get_max_bid(soup)
            bagged = self.is_bagged(soup)
            self.log(f"Extracted hand: {hand}")
            self.log(f"It's my turn to bid. Current max bid: {max_bid}")

            value, suit = evaluate_hand_bid(hand)

            if bagged:
                self.place_bid(15, suit)
            elif value > max_bid:
                self.place_bid(value, suit)
            else:
                self.place_bid(0, Suit.PASS)

            self.wait_until(
                lambda: self.get_phase(self.snapshot()) != "Bidding"
                or not self.is_my_turn(self.snapshot()),
                ACTION_TIMEOUT,
                "bid acceptance",
            )

        raise TimeoutException("Bidding phase timed out.")

    def place_bid(self, bid_value: int, bid_suit: Suit) -> None:
        if bid_value == 0 or bid_suit == Suit.PASS:
            WebDriverWait(self.driver, ACTION_TIMEOUT).until(
                EC.element_to_be_clickable((By.ID, "pass-bid-button"))
            ).click()
            self.log("Passed the bid.")
            return

        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((
                By.CSS_SELECTOR,
                f"button[phx-value-bid-number='{bid_value}']:not([disabled])",
            ))
        ).click()
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((
                By.CSS_SELECTOR,
                f"button[phx-value-bid-suit='{bid_suit.long_name()}']:not([disabled])",
            ))
        ).click()
        WebDriverWait(self.driver, ACTION_TIMEOUT).until(
            EC.element_to_be_clickable((
                By.CSS_SELECTOR,
                "#confirm-bid-button:not([disabled])",
            ))
        ).click()
        self.log(f"Placed bid {bid_value} {bid_suit.long_name()}.")

    # ── Phase: Discard ──────────────────────────────────────────────

    def discard_phase(self) -> None:
        deadline = time.time() + PHASE_TIMEOUT

        while time.time() < deadline:
            soup = self.snapshot()
            phase = self.get_phase(soup)
            if phase != "Discard":
                return

            if self.resume_control_if_needed(soup):
                continue

            if self.has_confirmed_discard(soup):
                time.sleep(POLL_INTERVAL)
                continue

            trump = self.get_trump(soup)
            hand = self.extract_hand(soup)
            self.log(f"Extracted hand: {hand}")
            self.log(f"Player hand before discarding: {hand}")

            keep = [c for c in hand if c.suit == trump or c.value == 13]
            if not keep:
                keep = hand[:5]
            keep = keep[:5]

            self.log(f"Keeping cards: {keep}")
            for card in keep:
                self.select_card(card)

            WebDriverWait(self.driver, ACTION_TIMEOUT).until(
                EC.element_to_be_clickable((By.ID, "confirm-discard-button"))
            ).click()
            self.log("Confirmed discard.")

            # Block until we leave the Discard phase entirely.
            # This prevents re-entering the discard logic if the server
            # briefly resets confirm_discard_clicked between rounds.
            self.wait_until(
                lambda: self.get_phase(self.snapshot()) != "Discard",
                PHASE_TIMEOUT,
                "discard phase to end",
            )
            return

        raise TimeoutException("Discard phase timed out.")

    # ── Phase: Playing ──────────────────────────────────────────────

    def playing_phase(self) -> None:
        deadline = time.time() + PHASE_TIMEOUT

        while time.time() < deadline:
            soup = self.snapshot()
            phase = self.get_phase(soup)
            if phase != "Playing":
                return

            if self.resume_control_if_needed(soup):
                continue

            if not self.is_my_turn(soup):
                time.sleep(POLL_INTERVAL)
                continue

            hand = self.extract_hand(soup, playable_only=True)
            played_cards = self.extract_played_cards(soup)
            trump = self.get_trump(soup)
            suit_led = self.get_suit_led(soup)

            if not hand:
                raise RuntimeError("No legal cards available on my turn.")
            if trump is None:
                raise RuntimeError("Trump suit is missing during playing phase.")

            self.log(f"Extracted playable hand: {hand}")
            self.log(f"Current played cards: {played_cards}")
            self.log(f"It's my turn to play. Trump: {trump}, suit led: {suit_led}")

            card_to_play = evaluate_hand_play(
                suit_led=suit_led,
                player_hand=hand,
                current_cards=played_cards,
                trump=trump,
            )
            self.select_card(card_to_play)

            WebDriverWait(self.driver, ACTION_TIMEOUT).until(
                EC.element_to_be_clickable((
                    By.CSS_SELECTOR,
                    "#play-card-button:not([disabled])",
                ))
            ).click()
            self.log("Played selected card.")

            self.wait_until(
                lambda: self.get_phase(self.snapshot()) != "Playing"
                or not self.is_my_turn(self.snapshot()),
                ACTION_TIMEOUT,
                "played card acceptance",
            )
            self.after_card_played()
            if self.finished:
                return

        raise TimeoutException("Playing phase timed out.")

    # ── Phase: Scoring ──────────────────────────────────────────────

    def scoring_phase(self) -> str:
        """Wait for scoring to end. Returns the next phase."""
        deadline = time.time() + PHASE_TIMEOUT

        while time.time() < deadline:
            soup = self.snapshot()
            phase = self.get_phase(soup)

            if phase == "Final Scoring":
                self.log("Final Scoring detected. Exiting the game.")
                return "Final Scoring"

            if phase != "Scoring":
                self.log("Scoring phase complete.")
                return phase

            time.sleep(POLL_INTERVAL)

        raise TimeoutException("Scoring phase timed out.")

    # ── Failure artifacts ───────────────────────────────────────────

    def capture_failure_artifacts(self) -> None:
        if self.driver is None:
            return

        artifact_dir = Path(os.getenv("TBOT_ARTIFACT_DIR", "artifacts"))
        artifact_dir.mkdir(parents=True, exist_ok=True)

        screenshot_path = artifact_dir / f"tbot_{self.instance}_failure.png"
        html_path = artifact_dir / f"tbot_{self.instance}_failure.html"

        try:
            self.driver.save_screenshot(str(screenshot_path))
            html_path.write_text(self.driver.page_source, encoding="utf-8")
            self.log(f"Saved failure artifacts to {screenshot_path} and {html_path}.")
        except WebDriverException as error:
            self.log(f"Failed to save debug artifacts: {error!r}")

    def close_driver(self) -> None:
        if self.driver is None:
            return
        self.driver.quit()
        self.driver = None
        print("\nWebDriver closed", flush=True)

    # ── Main loop ───────────────────────────────────────────────────

    def run(self) -> None:
        self.log(f"Scenario: {self.scenario}")
        self.enter_game()
        start_time = time.time()

        while time.time() - start_time < TOTAL_RUNTIME_TIMEOUT:
            if self.finished:
                return
            soup = self.snapshot()
            phase = self.get_phase(soup)

            if phase == "Bidding":
                self.bidding_phase()
            elif phase == "Discard":
                self.discard_phase()
            elif phase == "Playing":
                self.playing_phase()
            elif phase in ("Scoring", "Final Scoring"):
                result = self.scoring_phase()
                if result == "Final Scoring":
                    return
            else:
                raise RuntimeError(f"Unexpected game phase: {phase!r}")

        raise TimeoutException("Total runtime timeout exceeded.")


def main() -> None:
    phx_web = PhxWeb(os.getenv("APP_BASE_URL", "http://localhost:4000/play"))
    try:
        phx_web.run()
        phx_web.log("Scenario passed.")
    except Exception as error:
        phx_web.log(f"Run failed: {type(error).__name__}: {error}".rstrip())
        phx_web.capture_failure_artifacts()
        raise
    finally:
        phx_web.close_driver()


if __name__ == "__main__":
    main()
