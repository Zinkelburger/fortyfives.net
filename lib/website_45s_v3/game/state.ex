defmodule Website45sV3.Game.State do
  @moduledoc """
  Everything `Website45sV3.Game.GameController` knows about one running game.

  Every field is required, so a state is always complete: `new/1` raises on a
  missing or misspelled key instead of letting the game run with a hole in
  it. The fields fall into four groups, in the order they are declared:

    * the hand being played (dealt again by every new hand),
    * who controls each seat and the timers the game process has running,
    * the game as a whole (scores, where it came from),
    * the event log (`Website45sV3.Game.GameEvents`).

  Players never see this struct: they get the per-seat map built by
  `GameController.player_view/2`.
  """

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Deck
  alias Website45sV3.Game.Phase
  alias Website45sV3.Game.Suit

  @typedoc "A seat's id: the visitor's anonymous id, or `\"bot_...\"` for a bot seat."
  @type player_id :: String.t()

  @type team :: :team1 | :team2

  @typedoc "A card on the table, with the seat that played it."
  @type played_card :: %{player_id: player_id(), card: Card.t()}

  @typedoc """
  A running turn or discard timer: who it plays for (`:bot` moves the seat,
  `:idle` hands an idle human's seat to a bot) and, for idle timers, the
  `deadline` shown to the player as a countdown.
  """
  @type timer :: %{
          required(:kind) => :idle | :bot,
          required(:ref) => reference(),
          optional(:player_id) => player_id(),
          optional(:phase) => Phase.t(),
          optional(:deadline) => integer() | nil
        }

  @type t :: %__MODULE__{
          # The hand being played.
          phase: Phase.t(),
          current_player_id: player_id() | nil,
          dealing_player_id: player_id(),
          player_ids: [player_id()],
          player_map: %{player_id() => String.t()},
          hands: %{player_id() => [Card.t()]},
          legal_moves: %{player_id() => [Card.t()]},
          deck: Deck.t(),
          discard_pile: [Card.t()],
          actions: [String.t()],
          winning_bid: {non_neg_integer(), player_id() | nil, Suit.t() | nil},
          bids: %{player_id() => {non_neg_integer(), Suit.t() | :pass}},
          bids_placed: 0..4,
          received_discards_from: [player_id()],
          bagged: boolean(),
          suit_led: Suit.t() | nil,
          trump: Suit.t() | nil,
          played_cards: [played_card()],
          trick_winning_cards: [played_card()],
          round_scores: %{team() => integer()},
          # Seat control and timers.
          active_players: [player_id()],
          seat_bots: MapSet.t(player_id()),
          auto_play_players: MapSet.t(player_id()),
          abandoned_players: MapSet.t(player_id()),
          seen_players: MapSet.t(player_id()),
          turn_timer: timer() | nil,
          discard_timers: %{player_id() => timer()},
          termination_timer_ref: reference() | nil,
          all_bot_controlled_timer_ref: reference() | nil,
          unattended_timer: {reference(), reference()} | nil,
          # The game as a whole.
          game_name: String.t(),
          team_scores: %{team() => integer()},
          team_1_history: [String.t()],
          team_2_history: [String.t()],
          winning_team: team() | nil,
          rematch_id: String.t() | nil,
          queue: String.t(),
          lobby: String.t() | nil,
          # The event log.
          events: [map()],
          started_at: integer(),
          started_at_utc: DateTime.t()
        }

  @fields [
    :phase,
    :current_player_id,
    :dealing_player_id,
    :player_ids,
    :player_map,
    :hands,
    :legal_moves,
    :deck,
    :discard_pile,
    :actions,
    :winning_bid,
    :bids,
    :bids_placed,
    :received_discards_from,
    :bagged,
    :suit_led,
    :trump,
    :played_cards,
    :trick_winning_cards,
    :round_scores,
    :active_players,
    :seat_bots,
    :auto_play_players,
    :abandoned_players,
    :seen_players,
    :turn_timer,
    :discard_timers,
    :termination_timer_ref,
    :all_bot_controlled_timer_ref,
    :unattended_timer,
    :game_name,
    :team_scores,
    :team_1_history,
    :team_2_history,
    :winning_team,
    :rematch_id,
    :queue,
    :lobby,
    :events,
    :started_at,
    :started_at_utc
  ]

  @enforce_keys @fields
  defstruct @fields

  @doc """
  Builds a state from a map holding every field. Raises `ArgumentError` when
  one is missing and `KeyError` when one is not a field.
  """
  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
