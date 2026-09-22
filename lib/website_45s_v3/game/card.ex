defmodule Website45sV3.Game.Card do
  @moduledoc """
  A playing card and the 45s card ranking.

  Ranking in 45s depends on whether a card is trump, of the suit led, or
  neither. `less_than/4` implements that ordering as a strict total order so
  that any two distinct cards compare consistently in either direction.
  """

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Suit

  @type t :: %__MODULE__{value: 1..13, suit: Suit.t()}

  @enforce_keys [:value, :suit]
  defstruct [:value, :suit]

  @suits [:hearts, :diamonds, :clubs, :spades]

  @suit_atoms %{
    "hearts" => :hearts,
    "diamonds" => :diamonds,
    "clubs" => :clubs,
    "spades" => :spades
  }

  @suit_letters %{hearts: "H", diamonds: "D", clubs: "C", spades: "S"}

  @value_letters %{1 => "A", 11 => "J", 12 => "Q", 13 => "K"}

  @value_names %{1 => "Ace", 11 => "Jack", 12 => "Queen", 13 => "King"}

  # Ranks of the top trumps, above every other trump. The ace of hearts is
  # always the third-highest trump whatever the trump suit.
  @top_trump_ranks %{5 => 17, 11 => 16}
  @ace_of_hearts_rank 15
  @trump_court_ranks %{1 => 14, 13 => 13, 12 => 12}

  # Low cards rank "high in red, low in black": red pips count face value,
  # black pips count in reverse (the 2 beats the 10).
  @black_suits [:clubs, :spades]

  # Used to break ties between cards that can neither win nor follow the
  # trick, so that the ordering is total (see `less_than/4`).
  @suit_order %{hearts: 0, diamonds: 1, clubs: 2, spades: 3}

  def new(value, suit) when value in 1..13 and suit in @suits do
    %__MODULE__{value: value, suit: suit}
  end

  @doc """
  Parses a `"value_suit"` string (e.g. `"10_hearts"`) into a card.

  Returns `{:ok, card}` or `:error`. Never raises, so it is safe to call on
  untrusted client input.
  """
  def parse(card_string) when is_binary(card_string) do
    with [value_str, suit_str] <- String.split(card_string, "_"),
         {value, ""} when value in 1..13 <- Integer.parse(value_str),
         {:ok, suit} <- Map.fetch(@suit_atoms, suit_str) do
      {:ok, new(value, suit)}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  Encodes a card as a `"value_suit"` string, the inverse of `parse/1`.
  """
  def encode(%__MODULE__{value: value, suit: suit}) do
    "#{value}_#{Atom.to_string(suit)}"
  end

  @doc """
  Human readable name, e.g. `"5 of Hearts"` or `"Ace of Spades"`.
  """
  def to_string(%{value: value, suit: suit}) do
    value_string = Map.get(@value_names, value, Integer.to_string(value))
    "#{value_string} of #{Suit.to_string(suit)}"
  end

  @doc """
  Whether the card is the ace of hearts, which is always a trump.
  """
  def ace_of_hearts?(%{suit: :hearts, value: 1}), do: true
  def ace_of_hearts?({:hearts, 1}), do: true
  def ace_of_hearts?(_), do: false

  @doc """
  Whether the card counts as a trump: any card of the trump suit, plus the
  ace of hearts.
  """
  def trump?(%{suit: suit} = card, trump), do: suit == trump or ace_of_hearts?(card)

  @doc """
  The rank of a card played as a trump. Higher is better.
  """
  def eval_trump({:hearts, 1}, _trump), do: @ace_of_hearts_rank

  def eval_trump({trump, value}, trump) do
    Map.get(@top_trump_ranks, value) ||
      Map.get(@trump_court_ranks, value) ||
      pip_rank(trump, value)
  end

  def eval_trump({_suit, value}, _trump), do: value

  @doc """
  The rank of a non-trump card. Higher is better.
  """
  def eval_offsuite({suit, value}) when value in 2..10, do: pip_rank(suit, value)
  def eval_offsuite({suit, 1}) when suit in @black_suits, do: 10
  def eval_offsuite({_suit, value}), do: value

  defp pip_rank(suit, value) when suit in @black_suits, do: 11 - value
  defp pip_rank(_suit, value), do: value

  @doc """
  Returns `card1 < card2` for the trick in progress: `suit_led` is the suit
  led (`nil` when leading) and `trump` the trump suit.

  Trumps beat the led suit, which beats everything else. Two cards that can
  neither win nor follow are ordered by their off-suit rank and then suit,
  so that the relation is a strict total order over distinct cards.
  """
  def less_than(%Card{} = card1, %Card{} = card2, suit_led, trump) do
    rank(card1, suit_led, trump) < rank(card2, suit_led, trump)
  end

  # A card's rank is a tuple ordered lexicographically: its class (trump,
  # led suit or other) first, then its strength within that class.
  defp rank(%Card{value: value, suit: suit} = card, suit_led, trump) do
    cond do
      trump?(card, trump) -> {2, eval_trump({suit, value}, trump), 0}
      suit == suit_led -> {1, eval_offsuite({suit, value}), 0}
      true -> {0, eval_offsuite({suit, value}), Map.fetch!(@suit_order, suit)}
    end
  end

  @doc """
  The image file base name for a card, e.g. `"AH"` or `"10D"`.
  Accepts the suit as an atom or a string; returns `:error` for junk.
  """
  def card_to_filename({value, suit}) when is_binary(suit) do
    case Map.fetch(@suit_atoms, suit) do
      {:ok, suit_atom} -> card_to_filename({value, suit_atom})
      :error -> :error
    end
  end

  def card_to_filename({value, suit}) when suit in @suits and value in 1..13 do
    Map.get(@value_letters, value, Integer.to_string(value)) <> Map.fetch!(@suit_letters, suit)
  end

  def card_to_filename(_arg), do: :error
end
