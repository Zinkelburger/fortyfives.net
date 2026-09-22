defmodule Website45sV3.Game.Deck do
  @moduledoc """
  A 52 card deck: creation, shuffling and drawing.
  """

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Suit

  @type t :: %__MODULE__{cards: [Card.t()]}

  defstruct cards: []

  @doc """
  Creates a new, unshuffled deck of cards.
  """
  def new do
    cards =
      for suit <- Suit.all_suits(),
          value <- 1..13,
          do: Card.new(value, suit)

    %__MODULE__{cards: cards}
  end

  @doc """
  Shuffles the deck. `Enum.shuffle/1` is a uniform shuffle, so a single
  pass is all that is needed.
  """
  def shuffle(deck) do
    %{deck | cards: Enum.shuffle(deck.cards)}
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
