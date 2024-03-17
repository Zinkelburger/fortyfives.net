defmodule Suit do
  @moduledoc """
    - `t`: hearts, diamonds, clubs, spades

    - `to_string/1`: Suit atom to its string representation. ArgumentError for invalid suits.
    - `all_suits/0`: Returns a list of all suit atoms.
  """
  @type t :: :hearts | :diamonds | :clubs | :spades

  @suits %{
    hearts: "Hearts",
    diamonds: "Diamonds",
    clubs: "Clubs",
    spades: "Spades"
  }

  def to_string(suit) do
    case Map.fetch(@suits, suit) do
      {:ok, string} -> string
      :error -> raise ArgumentError, "Invalid suit: #{inspect(suit)}"
    end
  end

  def all_suits do
    Map.keys(@suits)
  end
end
