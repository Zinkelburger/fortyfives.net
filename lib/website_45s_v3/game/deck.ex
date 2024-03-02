defmodule Deck do
  alias Website45sV3.Game.Card
  @type t :: %__MODULE__{cards: [Card.t()]}

  defstruct cards: []

  @doc """
  Creates a new deck of cards.
  """
  def new do
    suits = Suit.all_suits()
    values = 1..13

    cards =
      for suit <- suits,
          value <- values,
          do: Card.new(value, suit)

    %Deck{cards: cards}
  end

  @doc """
  Shuffles the deck of cards.
  """
  def shuffle(deck) do
    %{deck | cards: Enum.shuffle(deck.cards)}
  end

  @doc """
  Shuffles the deck of cards a specified number of times.
  """
  def shuffle(deck, times) do
    cards = Enum.reduce(1..times, deck.cards, fn _, acc -> Enum.shuffle(acc) end)
    %{deck | cards: cards}
  end

  @doc """
  Removes the top card from the deck.
  """
  def remove_card(deck) do
    [card | remaining_cards] = deck.cards
    {card, %{deck | cards: remaining_cards}}
  end

  @doc """
  Returns the top card of the deck without removing it.
  """
  def top_card(deck) do
    [card | _] = deck.cards
    card
  end
end
