from enum import Enum


class Suit(Enum):
    HEARTS = "H"
    DIAMONDS = "D"
    CLUBS = "C"
    SPADES = "S"
    PASS = "pass"

    def long_name(self) -> str:
        return {
            "H": "hearts",
            "D": "diamonds",
            "C": "clubs",
            "S": "spades",
            "pass": "pass",
        }[self.value]


class Card:
    value_mapping = {"A": 1, "K": 13, "Q": 12, "J": 11}

    def __init__(self, value: str, suit: Suit) -> None:
        if value in Card.value_mapping:
            self.value = Card.value_mapping[value]
        else:
            self.value = int(value)
        self.suit = suit

    def __repr__(self) -> str:
        return f"{self.value}{self.suit.value}"


def is_ace_of_hearts(card) -> bool:
    return card.suit == Suit.HEARTS and card.value == 1


def eval_trump(card: Card, trump: Suit) -> int:
    suit, value = card.suit, card.value
    if suit == trump:
        if value == 5:
            return 17
        if value == 11:
            return 16
    if suit == Suit.HEARTS and value == 1:
        return 15
    if suit == trump:
        if value == 1:
            return 14
        if value == 13:
            return 13
        if value == 12:
            return 12
        # invert these suits for their low cards
        if suit in [Suit.SPADES, Suit.CLUBS] and value in [2, 3, 4, 6, 7, 8, 9, 10]:
            return 11 - value
    return value


def eval_offsuite(card: Card) -> int:
    suit, value = card.suit, card.value
    if suit in [Suit.SPADES, Suit.CLUBS] and value in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]:
        return 11 - value
    return value


def less_than(card1: Card, card2: Card, suit_led: Suit, trump: Suit) -> bool:
    if is_ace_of_hearts(card1) and card2.suit == trump:
        return eval_trump(card1, trump) < eval_trump(card2, trump)

    if is_ace_of_hearts(card1) and card2.suit != trump:
        return False

    if card1.suit == trump and is_ace_of_hearts(card2):
        return eval_trump(card1, trump) < eval_trump(card2, trump)

    if card1.suit != trump and is_ace_of_hearts(card2):
        return True

    if card1.suit == trump and card2.suit != trump:
        return False

    if card1.suit != trump and card2.suit == trump:
        return True

    if card1.suit == trump and card2.suit == trump:
        return eval_trump(card1, trump) < eval_trump(card2, trump)

    if card1.suit == suit_led and card2.suit != suit_led:
        return False

    if card1.suit != suit_led and card2.suit == suit_led:
        return True

    if card1.suit == suit_led and card2.suit == suit_led:
        return eval_offsuite(card1) < eval_offsuite(card2)

    return True
