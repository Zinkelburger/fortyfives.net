import json
import os
import time
from pathlib import Path
from typing import Callable, Optional

from card import Suit, Card, less_than, is_ace_of_hearts
from selenium import webdriver
from selenium.common.exceptions import (
    NoSuchElementException,
    StaleElementReferenceException,
    TimeoutException,
    WebDriverException,
)
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.remote.webelement import WebElement
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

ACTION_TIMEOUT_SECONDS = 20
JOIN_TIMEOUT_SECONDS = 120
MATCH_TIMEOUT_SECONDS = 180
PHASE_TIMEOUT_SECONDS = {
    "Bidding": 180,
    "Discard": 180,
    "Playing": 300,
    "Scoring": 90,
}
POLL_INTERVAL_SECONDS = 0.5
TOTAL_RUNTIME_TIMEOUT_SECONDS = 900


def get_driver() -> webdriver.Chrome:
    """
    Returns a Chrome WebDriver instance.
    Prefers a manually installed chromedriver at /usr/local/bin/chromedriver;
    falls back to Selenium Manager-managed driver if not found.
    """
    chrome_options = Options()
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")
    chrome_options.add_argument("--headless=new")

    chromedriver_path = "/usr/local/bin/chromedriver"
    if os.path.exists(chromedriver_path):
        service = Service(executable_path=chromedriver_path)
        return webdriver.Chrome(service=service, options=chrome_options)

    # Selenium Manager will handle downloading the correct driver
    return webdriver.Chrome(options=chrome_options)

def evaluate_hand_bid(player_hand: list[Card]) -> tuple[int, Suit]:
    # eventually have it reference a lookup table
    # always returns a suit, but may return a value less than 15
    # counters for each suit
    small_cards = {Suit.HEARTS: 0, Suit.DIAMONDS: 0, Suit.CLUBS: 0, Suit.SPADES: 0}
    sure_points = {Suit.HEARTS: 0, Suit.DIAMONDS: 0, Suit.CLUBS: 0, Suit.SPADES: 0}

    # idk just made it up. Be aggressive!
    face_card_points = {5: 12, 11: 6, 1: 4, 13: 3, 12: 2}

    # Iterate over the player's hand
    for card in player_hand:
        # if its the ace of hearts, give everybody 5 points
        if is_ace_of_hearts(card):
            for key in sure_points:
                sure_points[key] += 5
        elif card.value in face_card_points:
            sure_points[card.suit] += face_card_points[card.value]
        else:
            small_cards[card.suit] += 1

    # Find the suit with the maximum sure points
    max_sure_suit = max(sure_points, key=sure_points.get)
    # each small card is 3 points (felt like 5 + small card should be 15)
    estimated_value = small_cards[max_sure_suit] * 3 + sure_points[max_sure_suit]

    # Value bigger than 15 (rounded down to multiples of 5), else pass
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
    bid_amount: int,
    trump: Suit,
) -> Card:
    # get best card played so far
    if not current_cards:
        print("No cards have been played yet.")
        max_card = None
    else:
        # Get the best card played so far
        max_card = get_max_card(current_cards, suit_led, trump)

    # get player's best card
    players_max_card = get_max_card(player_hand, suit_led, trump)

    # Find the player's lowest card
    players_lowest_offsuite = players_lowest_offsuite = get_min_card(
        [card for card in player_hand if card.suit != suit_led and card.suit != trump],
        suit_led,
        trump,
    )
    # Find the player's worst trump card
    players_worst_trump = (
        get_min_card(
            [card for card in player_hand if card.suit == trump], suit_led, trump
        )
        if any(card.suit == trump for card in player_hand)
        else None
    )

    print(
        f"best: {max_card} players max: {players_max_card} players_worst_trump: {players_worst_trump} players_lowest_offsuite: {players_lowest_offsuite}"
    )

    # if no cards played, play your best card
    if not max_card:
        return players_max_card

    # will we beat the max card with our best card?
    # else play lowest offsuite
    if not less_than(players_max_card, max_card, suit_led, trump):
        return players_max_card
    # have to follow suit
    elif suit_led == trump and players_worst_trump:
        return players_worst_trump
    elif players_lowest_offsuite:
        return players_lowest_offsuite

    # log error and return the first card
    print(f"Evaluation of player hand failed: {player_hand}")
    return player_hand[0]


class GameState:
    def __init__(self) -> None:
        self.player_hand: list[Card] = []
        self.max_bid = 0
        self.current_played_cards = []
        self.is_current_turn = False
        self.is_bagged = False
        self.auto_playing = False
        self.confirm_discard_clicked = False
        self.phase = ""
        self.trump: Optional[Suit] = None
        self.suit_led: Optional[Suit] = None

    def reset(self) -> None:
        self.player_hand: list[Card] = []
        self.max_bid = 0
        self.current_played_cards = []
        self.is_current_turn = False
        self.is_bagged = False
        self.auto_playing = False
        self.confirm_discard_clicked = False
        self.phase = ""
        self.trump = None
        self.suit_led = None

    def __repr__(self) -> str:
        return (
            f"GameState(player_hand={self.player_hand}, max_bid={self.max_bid}, "
            f"current_played_cards={self.current_played_cards}, phase={self.phase}, "
            f"is_current_turn={self.is_current_turn}, auto_playing={self.auto_playing})"
        )


class PhxWeb:
    def __init__(self, url: str) -> None:
        self.url = url
        self.game_state = GameState()
        self.driver = get_driver()
        self.instance = os.getenv("TBOT_INSTANCE", str(os.getpid()))

    def log(self, message: str) -> None:
        print(f"[tbot {self.instance}] {message}", flush=True)

    def wait_for(self, predicate: Callable[[], bool], timeout: int, description: str) -> None:
        deadline = time.time() + timeout
        last_error: Optional[Exception] = None

        while time.time() < deadline:
            try:
                if predicate():
                    return
            except (
                NoSuchElementException,
                StaleElementReferenceException,
                TimeoutException,
                WebDriverException,
                json.JSONDecodeError,
            ) as error:
                last_error = error

            time.sleep(POLL_INTERVAL_SECONDS)

        raise TimeoutException(
            f"Timed out waiting for {description}. Last error: {last_error!r}"
        )

    def root(self) -> WebElement:
        return WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.presence_of_element_located((By.ID, "game-container"))
        )

    def read_game_state(self) -> GameState:
        root = self.root()
        self.game_state.phase = root.get_attribute("data-phase") or ""
        self.game_state.is_current_turn = (
            root.get_attribute("data-current-turn") == "true"
        )
        self.game_state.is_bagged = root.get_attribute("data-bagged") == "true"
        self.game_state.auto_playing = (
            root.get_attribute("data-auto-playing") == "true"
        )
        self.game_state.confirm_discard_clicked = (
            root.get_attribute("data-confirm-discard-clicked") == "true"
        )
        self.game_state.max_bid = int(root.get_attribute("data-current-bid") or "0")

        trump = root.get_attribute("data-trump")
        suit_led = root.get_attribute("data-suit-led")
        self.game_state.trump = self.parse_optional_suit(trump)
        self.game_state.suit_led = self.parse_optional_suit(suit_led)
        return self.game_state

    def current_phase(self) -> str:
        return self.read_game_state().phase

    def selected_cards(self) -> list[str]:
        hand = self.driver.find_element(By.ID, "player-hand")
        raw_cards = hand.get_attribute("data-selected-cards") or "[]"
        return json.loads(raw_cards)

    def parse_card_dom_value(self, card_dom_value: str) -> Card:
        value, suit = card_dom_value.split("_")
        return Card(value, Suit[suit.upper()])

    def parse_optional_suit(self, raw_value: Optional[str]) -> Optional[Suit]:
        if not raw_value:
            return None

        normalized = raw_value.strip().lower()
        if normalized in {"", "nil", "none"}:
            return None

        return Suit[normalized.upper()]

    def card_selector(self, card: Card) -> str:
        return f"img[data-card-value='{card.value}_{card.suit.long_name()}']"

    def click_join_queue(self) -> None:
        self.driver.get(self.url)
        WebDriverWait(self.driver, JOIN_TIMEOUT_SECONDS).until(
            EC.presence_of_element_located((By.ID, "queue-root"))
        )
        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.ID, "join-queue-button"))
        ).click()

        self.wait_for(
            lambda: "/game/" in self.driver.current_url
            or len(self.driver.find_elements(By.ID, "leave-queue-button")) == 1,
            ACTION_TIMEOUT_SECONDS,
            "queue join acknowledgement",
        )

        self.wait_for(
            lambda: "/game/" in self.driver.current_url,
            MATCH_TIMEOUT_SECONDS,
            "matchmaking redirect",
        )

        self.wait_for(
            lambda: len(self.driver.find_elements(By.ID, "game-container")) == 1,
            ACTION_TIMEOUT_SECONDS,
            "game page to load",
        )

        self.url = self.driver.current_url
        self.log(f"Redirected to {self.url}")

    def extract_player_hand(self, playable_only: bool = False) -> None:
        self.game_state.player_hand = []
        card_images = self.driver.find_elements(By.CSS_SELECTOR, "#player-hand img.card")
        for image in card_images:
            classes = image.get_attribute("class") or ""
            if playable_only and "grayed-out" in classes:
                continue
            card_value = image.get_attribute("data-card-value")
            if card_value:
                self.game_state.player_hand.append(self.parse_card_dom_value(card_value))

        hand_type = "playable hand" if playable_only else "hand"
        self.log(f"Extracted {hand_type}: {self.game_state.player_hand}")

    def place_bid(self, bid_value: int, bid_suit: Suit) -> None:
        if bid_value == 0 or bid_suit == Suit.PASS:
            WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
                EC.element_to_be_clickable((By.ID, "pass-bid-button"))
            ).click()
            self.log("Passed the bid.")
            return

        bid_value_selector = (
            By.CSS_SELECTOR,
            f"button[phx-value-bid-number='{bid_value}']:not([disabled])",
        )
        bid_suit_selector = (
            By.CSS_SELECTOR,
            f"button[phx-value-bid-suit='{bid_suit.long_name()}']:not([disabled])",
        )

        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable(bid_value_selector)
        ).click()
        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable(bid_suit_selector)
        ).click()
        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.CSS_SELECTOR, "#confirm-bid-button:not([disabled])"))
        ).click()
        self.log(f"Placed bid {bid_value} {bid_suit.long_name()}.")

    def bidding_phase(self) -> None:
        phase_started_at = time.time()

        while True:
            state = self.read_game_state()
            if state.phase != "Bidding":
                break

            if time.time() - phase_started_at > PHASE_TIMEOUT_SECONDS["Bidding"]:
                raise TimeoutException("Bidding phase never completed.")

            if state.auto_playing:
                self.resume_control_if_needed()
                continue

            if state.is_current_turn:
                self.extract_player_hand()
                self.log(f"It's my turn to bid. Current max bid: {state.max_bid}")
                value, suit = evaluate_hand_bid(self.game_state.player_hand)
                if state.is_bagged:
                    self.place_bid(15, suit)
                elif value > state.max_bid:
                    self.place_bid(value, suit)
                else:
                    self.place_bid(0, Suit.PASS)

                self.wait_for(
                    lambda: self.read_game_state().phase != "Bidding"
                    or not self.read_game_state().is_current_turn,
                    ACTION_TIMEOUT_SECONDS,
                    "bid to be accepted",
                )

            time.sleep(POLL_INTERVAL_SECONDS)

    def discard_phase(self) -> None:
        phase_started_at = time.time()

        while True:
            state = self.read_game_state()
            if state.phase != "Discard":
                break

            if time.time() - phase_started_at > PHASE_TIMEOUT_SECONDS["Discard"]:
                raise TimeoutException("Discard phase never completed.")

            if state.auto_playing:
                self.resume_control_if_needed()
                continue

            if state.confirm_discard_clicked:
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

            self.extract_player_hand()
            self.log(f"Player hand before discarding: {self.game_state.player_hand}")

            keep = []
            for card in self.game_state.player_hand:
                if card.suit == state.trump or card.value == 13:
                    keep.append(card)

            if not keep:
                keep = self.game_state.player_hand[:5]
            keep = keep[:5]

            self.log(f"Keeping cards: {keep}")
            for card in keep:
                self.select_card(card)

            WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
                EC.element_to_be_clickable((By.ID, "confirm-discard-button"))
            ).click()
            self.log("Confirmed discard.")

            self.wait_for(
                lambda: self.read_game_state().phase != "Discard"
                or self.read_game_state().confirm_discard_clicked,
                ACTION_TIMEOUT_SECONDS,
                "discard confirmation",
            )

            time.sleep(POLL_INTERVAL_SECONDS)

    def extract_current_cards(self) -> None:
        self.game_state.current_played_cards = []
        card_images = self.driver.find_elements(By.CSS_SELECTOR, "#table img[phx-value-card]")
        for image in card_images:
            card_value = image.get_attribute("phx-value-card")
            if card_value:
                self.game_state.current_played_cards.append(
                    self.parse_card_dom_value(card_value)
                )
        self.log(f"Current played cards: {self.game_state.current_played_cards}")

    def select_card(self, card: Card) -> None:
        card_value = f"{card.value}_{card.suit.long_name()}"
        if card_value in self.selected_cards():
            return

        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.CSS_SELECTOR, self.card_selector(card)))
        ).click()

        self.wait_for(
            lambda: card_value in self.selected_cards(),
            ACTION_TIMEOUT_SECONDS,
            f"{card_value} to be selected",
        )
        self.log(f"Selected card {card_value}.")

    def play_selected_card(self) -> None:
        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.CSS_SELECTOR, "#play-card-button:not([disabled])"))
        ).click()
        self.log("Played selected card.")

    def resume_control_if_needed(self) -> None:
        if not self.read_game_state().auto_playing:
            return

        buttons = self.driver.find_elements(By.ID, "resume-control-button")
        if not buttons:
            raise RuntimeError("Auto-play is enabled, but the resume button is missing.")

        WebDriverWait(self.driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.ID, "resume-control-button"))
        ).click()
        self.wait_for(
            lambda: not self.read_game_state().auto_playing,
            ACTION_TIMEOUT_SECONDS,
            "manual control to resume",
        )
        self.log("Resumed manual control.")

    def playing_phase(self) -> None:
        phase_started_at = time.time()
        while True:
            state = self.read_game_state()
            if state.phase != "Playing":
                break

            if time.time() - phase_started_at > PHASE_TIMEOUT_SECONDS["Playing"]:
                raise TimeoutException("Playing phase never completed.")

            if state.auto_playing:
                self.resume_control_if_needed()
                continue

            if state.is_current_turn:
                self.extract_player_hand(playable_only=True)
                self.extract_current_cards()

                if not self.game_state.player_hand:
                    raise RuntimeError("No legal cards available on the active turn.")
                if state.trump is None:
                    raise RuntimeError("Trump suit is missing during the playing phase.")

                self.log(
                    f"It's my turn to play. Trump: {state.trump}, suit led: {state.suit_led}"
                )
                card_to_play = evaluate_hand_play(
                    suit_led=state.suit_led,
                    player_hand=self.game_state.player_hand,
                    current_cards=self.game_state.current_played_cards,
                    bid_amount=state.max_bid,
                    trump=state.trump,
                )
                self.select_card(card_to_play)
                self.play_selected_card()
                self.wait_for(
                    lambda: self.read_game_state().phase != "Playing"
                    or not self.read_game_state().is_current_turn,
                    ACTION_TIMEOUT_SECONDS,
                    "played card to be accepted",
                )
            time.sleep(POLL_INTERVAL_SECONDS)

    def scoring_phase(self) -> None:
        phase_started_at = time.time()

        while True:
            phase = self.current_phase()

            if phase == "Final Scoring":
                self.log("Final Scoring detected. Exiting the game.")
                return

            if phase != "Scoring":
                break

            if time.time() - phase_started_at > PHASE_TIMEOUT_SECONDS["Scoring"]:
                raise TimeoutException("Scoring phase never completed.")

            time.sleep(POLL_INTERVAL_SECONDS)

        self.log("Scoring phase complete. Resetting game state.")
        self.game_state.reset()

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
            self.log(
                f"Saved failure artifacts to {screenshot_path} and {html_path}."
            )
        except WebDriverException as error:
            self.log(f"Failed to save debug artifacts: {error!r}")

    def close_driver(self) -> None:
        if self.driver is None:
            return

        self.driver.quit()
        self.driver = None
        print("\nWebDriver closed", flush=True)

    def run(self) -> None:
        self.click_join_queue()
        start_time = time.time()

        while time.time() - start_time < TOTAL_RUNTIME_TIMEOUT_SECONDS:
            phase = self.current_phase()

            if phase == "Bidding":
                self.bidding_phase()
            elif phase == "Discard":
                self.discard_phase()
            elif phase == "Playing":
                self.playing_phase()
            elif phase == "Scoring":
                self.scoring_phase()
            elif phase == "Final Scoring":
                self.log("Final Scoring detected. Exiting the game.")
                return
            else:
                raise RuntimeError(f"Unexpected game phase: {phase!r}")

        raise TimeoutException("Timed out waiting for the game to complete.")


def main() -> None:
    phx_web = PhxWeb(os.getenv("APP_BASE_URL", "http://localhost:4000/play"))
    try:
        phx_web.run()
    except Exception as error:
        phx_web.log(f"Run failed: {error!r}")
        phx_web.capture_failure_artifacts()
        raise
    finally:
        phx_web.close_driver()


if __name__ == "__main__":
    main()
