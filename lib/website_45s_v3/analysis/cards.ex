defmodule Website45sV3.Analysis.Cards do
  @moduledoc """
  Cards as integers for the analysis engine and bots: `id = suit * 13 + value - 1`
  with suits hearts, diamonds, clubs, spades = 0..3, so the ace of hearts is 0.
  This is the research engine's numbering; ranks and legal plays follow
  `Website45sV3.Game.Card` and `Website45sV3.Game.Rules` exactly.
  """
  import Bitwise
  alias Website45sV3.Game.Card

  @suits [:hearts, :diamonds, :clubs, :spades]
  @sidx %{hearts: 0, diamonds: 1, clubs: 2, spades: 3}
  @ace_hearts 0

  def ace_hearts, do: @ace_hearts
  def suits, do: @suits
  def suit_atom(i), do: Enum.at(@suits, i)
  def suit_index(atom), do: Map.fetch!(@sidx, atom)

  def suit(id), do: div(id, 13)
  def value(id), do: rem(id, 13) + 1
  def id(suit, value), do: suit * 13 + value - 1

  def from_card(%Card{suit: s, value: v}), do: @sidx[s] * 13 + v - 1
  def to_card(id), do: %Card{suit: suit_atom(suit(id)), value: value(id)}

  def encode(id), do: Card.encode(to_card(id))

  def parse(string) do
    case Card.parse(string) do
      {:ok, card} -> {:ok, from_card(card)}
      :error -> :error
    end
  end

  def name(id), do: Card.to_string(to_card(id))

  def trump?(id, trump), do: suit(id) == trump or id == @ace_hearts

  @doc "The suit a led card calls for: the ace of hearts leads trump."
  def suit_led(@ace_hearts, trump), do: trump
  def suit_led(id, _trump), do: suit(id)

  @doc """
  Strength of a card in a trick: trumps beat the suit led, which beats the
  rest. `led` is the suit led, or nil for a card that leads.
  """
  def rank(id, led, trump) do
    s = suit(id)
    v = value(id)

    cond do
      trump?(id, trump) -> 2000 + Card.eval_trump({suit_atom(s), v}, suit_atom(trump)) * 4
      s == led -> 1000 + Card.eval_offsuite({suit_atom(s), v}) * 4
      true -> Card.eval_offsuite({suit_atom(s), v}) * 4 + s
    end
  end

  @doc "Strength of a trump (0 for other cards), for the highest-trump bonus."
  def trump_rank(id, trump) do
    if trump?(id, trump),
      do: Card.eval_trump({suit_atom(suit(id)), value(id)}, suit_atom(trump)),
      else: 0
  end

  defp reneg?(id, trump), do: id == @ace_hearts or (suit(id) == trump and value(id) in [5, 11])

  @doc """
  The cards `hand` may play when `led` (a card id, or nil) has been led:
  follow suit or trump; the 5, jack and ace of hearts may be withheld when
  a lower trump is led. Same as `Rules.legal_moves/3`.
  """
  def legal(hand, nil, _trump), do: hand

  def legal(hand, led, trump) do
    sl = suit_led(led, trump)
    following = Enum.filter(hand, &(suit(&1) == sl or trump?(&1, trump)))

    cond do
      following == [] ->
        hand

      sl != trump and Enum.all?(following, &trump?(&1, trump)) ->
        hand

      Enum.all?(following, &reneg?(&1, trump)) and
          Enum.all?(following, &(rank(&1, sl, trump) >= rank(led, sl, trump))) ->
        hand

      true ->
        following
    end
  end

  @doc "Index into `cards` (played in order) of the card that wins the trick."
  def trick_winner(cards, trump) do
    sl = suit_led(hd(cards), trump)

    cards
    |> Enum.with_index()
    |> Enum.reduce(fn {c, i}, {bc, bi} ->
      if rank(c, sl, trump) > rank(bc, sl, trump), do: {c, i}, else: {bc, bi}
    end)
    |> elem(1)
  end

  def mask(ids), do: Enum.reduce(ids, 0, &(&2 ||| 1 <<< &1))

  @doc """
  Hand order the way most players hold cards: trump (with the ace of hearts)
  best first, then the other suits alternating colour.
  """
  @display_order %{
    nil => [0, 2, 1, 3],
    0 => [0, 2, 1, 3],
    1 => [1, 2, 0, 3],
    2 => [2, 0, 3, 1],
    3 => [3, 0, 2, 1]
  }
  def sort_for_display(ids, trump) do
    order = @display_order[trump]

    Enum.sort_by(ids, fn id ->
      cond do
        trump && trump?(id, trump) ->
          {0, -trump_rank(id, trump)}

        id == @ace_hearts ->
          {1 + Enum.find_index(order, &(&1 == 0)), -100}

        true ->
          {1 + Enum.find_index(order, &(&1 == suit(id))),
           -Card.eval_offsuite({suit_atom(suit(id)), value(id)})}
      end
    end)
  end
end
