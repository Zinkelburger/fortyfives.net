defmodule Website45sV3.Analysis.Variant do
  @moduledoc """
  The games the analysis board plays: the site's four-player partnership game
  and cutthroat (every player for themselves) for two to six players.

  Cutthroat follows the research engine's rules (Frank-45s-Opus,
  `approaches/cutthroat/ct_engine.hpp`): five cards each and a three-card kitty
  to the bidder, one bid each from the dealer's left, draws from the dealer's
  left, 5 a trick plus 5 for the highest trump to each player. With six
  players everyone keeps at least two cards, since 6 × 5 + 3 leaves only 19
  cards to draw from.
  """

  @enforce_keys [:id, :n, :teams]
  defstruct [:id, :n, :teams, min_keep: 1, draw_from_dealer_left: true]

  @type t :: %__MODULE__{
          id: String.t(),
          n: 2..6,
          teams: boolean(),
          min_keep: 1..2,
          draw_from_dealer_left: boolean()
        }

  @ids ~w(team4 ct2 ct3 ct4 ct5 ct6)

  def ids, do: @ids

  def all, do: Enum.map(@ids, &get!/1)

  def get("team4"),
    do: {:ok, %__MODULE__{id: "team4", n: 4, teams: true, draw_from_dealer_left: false}}

  def get("ct" <> n) when n in ~w(2 3 4 5 6) do
    n = String.to_integer(n)
    {:ok, %__MODULE__{id: "ct#{n}", n: n, teams: false, min_keep: if(n >= 6, do: 2, else: 1)}}
  end

  def get(_), do: :error

  def get!(id) do
    {:ok, variant} = get(id)
    variant
  end

  @doc "Short name for menus and headings."
  def label(%__MODULE__{teams: true}), do: "Partners"
  def label(%__MODULE__{n: n}), do: "Cutthroat · #{n} players"

  @doc "One line on how the variant is played."
  def summary(%__MODULE__{teams: true}), do: "4 players, 2 teams of 2. The site's game."
  def summary(%__MODULE__{n: 6}), do: "Every player for themselves. Keep at least 2."
  def summary(%__MODULE__{n: n}), do: "#{n} players, every player for themselves."

  @doc "Which score a seat adds to: its team in partners, itself in cutthroat."
  def side(%__MODULE__{teams: true}, seat), do: rem(seat, 2)
  def side(%__MODULE__{}, seat), do: seat

  def sides(%__MODULE__{teams: true}), do: 2
  def sides(%__MODULE__{n: n}), do: n
end
