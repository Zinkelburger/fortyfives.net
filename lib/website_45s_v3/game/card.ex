defmodule Website45sV3.Game.Card do
  alias Website45sV3.Game.Card
  @type t :: {integer(), Suit.t()}

  defstruct value: -1000, suit: :invalid

  def new(value \\ -1000, suit \\ :invalid) do
    %__MODULE__{value: value, suit: suit}
  end

  def to_string(card) do
    value_string =
      case card.value do
        13 -> "King"
        12 -> "Queen"
        11 -> "Jack"
        1 -> "Ace"
        _ -> Integer.to_string(card.value)
      end

    suit_string = Suit.to_string(card.suit)

    "#{value_string} of #{suit_string}"
  end

  @doc """
  whether or not the card is the ace of hearts
  """
  def is_ace_of_hearts?(%{suit: :hearts, value: 1}), do: true
  def is_ace_of_hearts?({:hearts, 1}), do: true
  def is_ace_of_hearts?(_), do: false

  def eval_trump({suit, value}, trump) do
    case {suit, value} do
      {^trump, 5} -> 17
      {^trump, 11} -> 16
      {:hearts, 1} -> 15
      {^trump, 1} -> 14
      {^trump, 13} -> 13
      {^trump, 12} -> 12
      {suit, n} when suit in [:spades, :clubs] and n in [2, 3, 4, 6, 7, 8, 9, 10] -> 11 - n
      _ -> value
    end
  end

  def eval_offsuite({suit, value}) do
    case {suit, value} do
      {suit, n} when suit in [:spades, :clubs] and n in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] -> 11 - n
      _ -> value
    end
  end

  @doc """
  returns card1 < card2, requires suit_led and trump
  """
  def less_than(
        %Website45sV3.Game.Card{value: value1, suit: suit1},
        %Website45sV3.Game.Card{value: value2, suit: suit2},
        suit_led,
        trump
      ) do
    cond do
      # ace of hearts
      Card.is_ace_of_hearts?({suit1, value1}) and suit2 == trump ->
        eval_trump({suit1, value1}, trump) < eval_trump({suit2, value2}, trump)

      Card.is_ace_of_hearts?({suit1, value1}) and suit2 != trump ->
        false

      suit1 == trump and Card.is_ace_of_hearts?({suit2, value2}) ->
        eval_trump({suit1, value1}, trump) < eval_trump({suit2, value2}, trump)

      suit1 != trump and Card.is_ace_of_hearts?({suit2, value2}) ->
        true

      # trump
      suit1 == trump and suit2 != trump ->
        false

      suit1 != trump and suit2 == trump ->
        true

      suit1 == trump and suit2 == trump ->
        eval_trump({suit1, value1}, trump) < eval_trump({suit2, value2}, trump)

      # offsuit
      suit1 == suit_led and suit2 != suit_led ->
        false

      suit1 != suit_led and suit2 == suit_led ->
        true

      suit1 == suit_led and suit2 == suit_led ->
        eval_offsuite({suit1, value1}) < eval_offsuite({suit2, value2})

      # I had :error before, but it is possible for the comparison to take place
      true ->
        true
    end
  end

  def card_to_filename({value, suit}) when is_binary(suit) do
    value_str =
      case value do
        1 -> "A"
        11 -> "J"
        12 -> "Q"
        13 -> "K"
        _ -> Integer.to_string(value)
      end

    suit_str =
      case suit do
        "hearts" -> "H"
        "diamonds" -> "D"
        "clubs" -> "C"
        "spades" -> "S"
      end

    "#{value_str}#{suit_str}"
  end

  def card_to_filename({value, suit}) do
    value_str =
      case value do
        1 -> "A"
        11 -> "J"
        12 -> "Q"
        13 -> "K"
        _ -> Integer.to_string(value)
      end

    suit_str =
      case suit do
        :hearts -> "H"
        :diamonds -> "D"
        :clubs -> "C"
        :spades -> "S"
      end

    "#{value_str}#{suit_str}"
  end

  def card_to_filename(arg) do
    IO.puts("Unexpected argument: #{inspect(arg)}")
    :error
  end
end
