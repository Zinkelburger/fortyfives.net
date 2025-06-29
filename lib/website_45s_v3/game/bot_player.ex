defmodule Website45sV3.Game.BotPlayer do
  @moduledoc """
  Basic automated player used when a participant is idle.
  The functions here return moves for the various phases of the game.
  """
  alias Website45sV3.Game.Card

  @doc """
  Returns a bid and suit. Currently always passes.
  """
  def pick_bid(_state, _player_id), do: {0, "pass"}

  @doc """
  Given the current `state` and the `player_id`, returns a list of card strings
  representing the cards to keep during the discard phase. The cards are ordered
  as they appear in the player's hand and the first five are kept.
  """
  def pick_discard(state, player_id) do
    state.hands
    |> Map.get(player_id, [])
    |> Enum.take(5)
    |> Enum.map(&format_card/1)
  end

  @doc """
  Chooses a card to play from the player's legal moves. If no legal moves are
  provided, the first card in their hand is selected.
  """
  def pick_card(state, player_id) do
    hand = Map.get(state.hands, player_id, [])
    legal = Map.get(state.legal_moves, player_id, hand)

    case legal do
      [] -> List.first(hand)
      _ -> List.first(legal)
    end
  end

  defp format_card(%Card{value: value, suit: suit}) do
    "#{value}_#{Atom.to_string(suit)}"
  end
end
