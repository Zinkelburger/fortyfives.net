import time
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from bs4 import BeautifulSoup
from card import Suit, Card, less_than, is_ace_of_hearts
from typing import Optional
import os


def get_driver() -> webdriver.Chrome:
    """
    Returns a Chrome WebDriver instance.
    Prefers a manually installed chromedriver at /usr/local/bin/chromedriver;
    falls back to Selenium Manager-managed driver if not found.
    """
    chrome_options = Options()
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")
    chrome_options.add_argument("--headless=new")

    chromedriver_path = "/usr/local/bin/chromedriver"
    if os.path.exists(chromedriver_path):
        service = Service(executable_path=chromedriver_path)
        return webdriver.Chrome(service=service, options=chrome_options)
    else:
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
        self.cum_cards_played = []
        self.current_played_cards = []
        self.is_current_turn = False
        self.my_turn = False
        self.is_bagged = False
        self.current_score = 0
        self.bids = []
        self.trump: Suit
        self.suit_led: Suit

    def reset(self) -> None:
        self.player_hand: list[Card] = []
        self.max_bid = 0
        self.cum_cards_played = []
        self.current_played_cards = []
        self.is_current_turn = False
        self.my_turn = False
        self.is_bagged = False
        self.current_score = 0
        self.bids = []
        self.trump: Suit = None
        self.suit_led: Suit = None

    def __repr__(self) -> str:
        return (
            f"GameState(player_hand={self.player_hand}, max_bid={self.max_bid}, "
            f"cards_played={self.cum_cards_played}, is_current_turn={self.is_current_turn}, "
            f"current_score={self.current_score}, bids={self.bids})"
        )


class PhxWeb:
    def __init__(self, url: str) -> None:
        self.url = url
        self.game_state = GameState()
        self.driver = get_driver()

    def click_join_queue(self) -> None:
        self.driver.get(self.url)
        WebDriverWait(self.driver, 60).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, ".green-button"))
        ).click()
        # Wait for redirect
        WebDriverWait(self.driver, 30).until(EC.url_changes(self.url))
        redirected_url = self.driver.current_url
        print(f"Redirected to: {redirected_url}")
        self.url = redirected_url

    def extract_player_hand(self, soup: BeautifulSoup) -> None:
        self.game_state.player_hand = []
        player_hand_div = soup.find("div", class_="player-hand")
        if player_hand_div:
            card_images = player_hand_div.find_all("img", class_="card")
            for img in card_images:
                card_name = img["src"].split("/")[-1].replace(".png", "")
                value = card_name[:-1]
                suit = Suit(card_name[-1])
                self.game_state.player_hand.append(Card(value, suit))
        print(f"Extracted player hand from game state: {self.game_state.player_hand}")

    def extract_player_hand_valid(self, soup: BeautifulSoup) -> None:
        self.game_state.player_hand = []
        player_hand_div = soup.find("div", class_="player-hand")
        if player_hand_div:
            # Cards that can be clicked have the class "card" and not "grayed-out"
            card_images = player_hand_div.find_all("img", class_="card")
            for img in card_images:
                card_name = img["src"].split("/")[-1].replace(".png", "")
                value = card_name[:-1]
                suit = Suit(card_name[-1])
                # Check if the card can be selected
                if "grayed-out" not in img.get("class", []):
                    self.game_state.player_hand.append(Card(value, suit))
        print(
            f"Extracted valid player hand from game state: {self.game_state.player_hand}"
        )

    def extract_bids(self, soup: BeautifulSoup) -> None:
        bids_div = soup.find("div", class_="actions-list")
        if bids_div:
            # Get the text directly from the div and split by commas
            bids_text = bids_div.get_text(strip=True)
            bids_parts = bids_text.split(",")

            for part in bids_parts:
                part = part.strip()
                if "bid" in part:
                    username, bid_value = part.split(" bid ")
                    bid_value = int(bid_value)
                    self.game_state.bids.append(
                        {"username": username.strip(), "bid": bid_value}
                    )
                    if bid_value > self.game_state.max_bid:
                        self.game_state.max_bid = bid_value
                elif " passed" in part:
                    username = part.split(" passed")[0]
                    self.game_state.bids.append(
                        {"username": username.strip(), "bid": 0}
                    )
            else:
                split_part = part.split()
                if len(split_part) > 0:
                    self.game_state.bids.append(
                        {"username": split_part[0].strip(), "bid": 0}
                    )
                else:
                    print(f"Unexpected format in bids: {part}")

        print(f"Extracted bids from game state: {self.game_state.bids}")

    def extract_current_turn(self, soup: BeautifulSoup) -> None:
        bagged_message = soup.find(
            "p", string=lambda text: text and "You are bagged" in text
        )
        current_turn_p = soup.find(
            "p", string=lambda text: text and "It is your turn" in text
        )
        turn_message_2 = soup.find(
            "p", string=lambda text: text and "Your turn" in text
        )

        if bagged_message:
            self.game_state.is_bagged = True
            self.game_state.is_current_turn = True
        elif current_turn_p or turn_message_2:
            self.game_state.is_bagged = False
            self.game_state.is_current_turn = True
        else:
            self.game_state.is_current_turn = False
            self.game_state.is_bagged = False
        print(
            f"Current turn status: {self.game_state.is_current_turn}, is bagged: {self.game_state.is_bagged}"
        )

    def place_bid(self, bid_value: int, bid_suit: Suit) -> None:
        if bid_value == 0 or bid_suit == Suit.PASS:
            pass_button = self.driver.find_element(By.CSS_SELECTOR, ".pass-button")
            pass_button.click()
        else:
            # Select the bid value
            bid_value_button = self.driver.find_element(
                By.CSS_SELECTOR, f"button[phx-value-bid-number='{bid_value}']"
            )
            print(f"clicked button[phx-value-bid-number='{bid_value}']")
            bid_value_button.click()

            # Select the bid suit
            bid_suit_button = self.driver.find_element(
                By.CSS_SELECTOR, f"button[phx-value-bid-suit='{bid_suit.long_name()}']"
            )
            print(f"clicked button[phx-value-bid-suit='{bid_suit.long_name()}']")
            bid_suit_button.click()
            time.sleep(1)  # Give some time for the confirm button to be enabled

            # Confirm the bid
            confirm_button = self.driver.find_element(
                By.CSS_SELECTOR, "button[phx-click='confirm_bid']"
            )
            confirm_button.click()

    def is_bidding_phase(self, soup: BeautifulSoup) -> bool:
        h1_tag = soup.find("h1")
        if h1_tag and "Bidding" in h1_tag.get_text():
            return True
        else:
            return False

    def bidding_phase(self) -> None:
        time.sleep(1)
        while True:
            soup = BeautifulSoup(self.driver.page_source, "html.parser")
            if not self.is_bidding_phase(soup):
                break
            self.extract_player_hand(soup)
            self.extract_bids(soup)
            self.extract_current_turn(soup)

            if self.game_state.is_current_turn:
                print(f"It's my turn to bid. Max bid: {self.game_state.max_bid}")
                value, suit = evaluate_hand_bid(self.game_state.player_hand)
                if self.game_state.is_bagged:
                    self.place_bid(15, suit)
                elif value > self.game_state.max_bid:
                    self.place_bid(value, suit)
                else:
                    self.place_bid(0, "pass")
            else:
                print("Waiting for my turn...")
            time.sleep(2)

    def extract_trump_soup(self, soup: BeautifulSoup) -> None:
        actions_div = soup.find("div", class_="actions-list")
        if actions_div:
            text = actions_div.get_text(strip=True)
            if "won with" in text:
                parts = text.split(" won with ")
                if len(parts) == 2:
                    bid_parts = parts[1].split()
                    if len(bid_parts) == 2:
                        self.game_state.max_bid = int(bid_parts[0])
                        self.game_state.trump = Suit(bid_parts[1][0].upper())
        print(
            f"Extracted trump suit and max bid: {self.game_state.trump}, {self.game_state.max_bid}"
        )

    def discard_phase(self) -> None:
        # get the trump & bid value
        soup = BeautifulSoup(self.driver.page_source, "html.parser")
        self.extract_trump_soup(soup)
        self.extract_player_hand(soup)

        # Print the player's hand before discarding
        print(f"Player hand before discarding: {self.game_state.player_hand}")

        # keep trump & kings
        keep = []
        for card in self.game_state.player_hand:
            if card.suit == self.game_state.trump:
                keep.append(card)
            elif card.value == 13:  # Keep kings
                keep.append(card)

        print(f"Keeping cards: {keep}")

        # if you didn't keep anything, keep the first five cards
        if not keep:
            keep = self.game_state.player_hand[:5]
        # never keep more than five cards
        keep = keep[:5]

        # Click the keep list cards
        for card in keep:
            try:
                card_element = WebDriverWait(self.driver, 10).until(
                    EC.element_to_be_clickable(
                        (
                            By.CSS_SELECTOR,
                            f"img[data-card-value='{card.value}_{card.suit.long_name()}']",
                        )
                    )
                )
                print(
                    f"clicking img[data-card-value='{card.value}_{card.suit.long_name()}']"
                )
                card_element.click()
                time.sleep(0.2)  # Adding a small delay between clicks
            except Exception as e:
                print(f"Failed to click card {card}: {e}")
                breakpoint()

        # Click confirm discard
        try:
            confirm_button = WebDriverWait(self.driver, 10).until(
                EC.element_to_be_clickable(
                    (By.CSS_SELECTOR, "button[phx-hook='ConfirmDiscardButton']")
                )
            )
            confirm_button.click()
        except Exception as e:
            print(f"Failed to click confirm discard button: {e}")

        # wait for other players to finish
        while True:
            soup = BeautifulSoup(self.driver.page_source, "html.parser")
            waiting = soup.find("p", string="Waiting for other players…")

            playing = soup.find("div", class_="played-cards")

            if not waiting and playing:
                print("👉 Transitioned to the Playing phase.")
                break

            print("Waiting for other players to finish…")
            time.sleep(2)

    def extract_current_cards(self, soup: BeautifulSoup) -> None:
        self.game_state.current_played_cards = []
        played_cards_div = soup.find("div", class_="table")
        if played_cards_div:
            card_images = played_cards_div.find_all("img")
            for img in card_images:
                card_name = img["phx-value-card"]
                value, suit = card_name.split("_")
                suit = Suit[suit.upper()]
                self.game_state.current_played_cards.append(Card(value, suit))
        print(f"Current played cards extracted: {self.game_state.current_played_cards}")

    def extract_card_led_suit(self, soup: BeautifulSoup) -> None:
        card_led_div = soup.find("div", id="card-led-suit")
        if card_led_div:
            suit = card_led_div.get_text(strip=True)
            print(f"suit led: {suit}")
            suit = suit.upper() if suit else "PASS"
            self.game_state.suit_led = Suit[suit]

    def playing_phase(self) -> None:
        while True:
            soup = BeautifulSoup(self.driver.page_source, "html.parser")
            if self.is_scoring_phase(soup):
                print("Transitioned to the Scoring phase.")
                break
            self.extract_player_hand_valid(soup)
            self.extract_current_turn(soup)
            self.extract_current_cards(soup)

            # Append the current hand cards to the global list of cards played
            self.game_state.cum_cards_played += self.game_state.current_played_cards

            # Extract the card led suit
            self.extract_card_led_suit(soup)

            if self.game_state.is_current_turn:
                time.sleep(0.3)
                print(f"It's my turn to play. Max bid: {self.game_state.max_bid}")
                print(f"Player hand: {self.game_state.player_hand}")
                print(f"Current cards: {self.game_state.current_played_cards}")
                card_to_play = evaluate_hand_play(
                    suit_led=self.game_state.suit_led,
                    player_hand=self.game_state.player_hand,
                    current_cards=self.game_state.current_played_cards,
                    bid_amount=self.game_state.max_bid,
                    trump=self.game_state.trump,
                )
                card_element = self.driver.find_element(
                    By.CSS_SELECTOR,
                    f"img[data-card-value='{card_to_play.value}_{card_to_play.suit.long_name()}']",
                )
                card_element.click()
                time.sleep(0.1)

                confirm_button = WebDriverWait(self.driver, 10).until(
                    EC.element_to_be_clickable(
                        (By.CSS_SELECTOR, "button[phx-hook='PlayCardButton']")
                    )
                )
                confirm_button.click()
            else:
                print("Waiting for my turn...")
            time.sleep(2)

    # responsible for exiting the game on final scoring
    def is_scoring_phase(self, soup: BeautifulSoup) -> bool:
        h1_tag = soup.find("h1")
        if h1_tag and "Scoring" in h1_tag.get_text():
            if "Final Scoring" in h1_tag.get_text():
                print("Final Scoring detected. Exiting the game.")
                self.close_driver()
                exit(0)
            return True
        else:
            return False

    def scoring_phase(self) -> None:
        while True:
            soup = BeautifulSoup(self.driver.page_source, "html.parser")
            if not self.is_scoring_phase(soup):
                break
            print("Waiting for scoring to complete...")
            time.sleep(2)
        print("Scoring phase complete. Resetting game state.")
        self.game_state.reset()

    def close_driver(self) -> None:
        self.driver.quit()
        print("\nWebDriver closed")


def main() -> None:
    phx_web = PhxWeb("http://localhost:4000/play")
    phx_web.click_join_queue()

    while True:
        phx_web.bidding_phase()
        phx_web.discard_phase()
        phx_web.playing_phase()
        phx_web.scoring_phase()


if __name__ == "__main__":
    main()
