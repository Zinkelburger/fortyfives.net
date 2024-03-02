defmodule Suit do
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
