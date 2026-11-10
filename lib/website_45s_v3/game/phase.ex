defmodule Website45sV3.Game.Phase do
  @moduledoc """
  The phases a hand moves through, in order:

      :bidding -> :discard -> :playing -> :scoring -> :bidding -> ...
                                       \\-> :final_scoring (the game is over)

  The game process and the table view match on these atoms. `label/1` is the
  name used wherever a phase leaves Elixir: the `data-phase` attribute read by
  the browser hooks and the test bots, and the game event log.
  """

  @type t :: :bidding | :discard | :playing | :scoring | :final_scoring

  @phases [:bidding, :discard, :playing, :scoring, :final_scoring]

  @doc "Every phase, in the order a hand goes through them."
  @spec all() :: [t()]
  def all, do: @phases

  @doc "The phase's name outside Elixir, from `Bidding` to `Final Scoring`."
  @spec label(t()) :: String.t()
  def label(:bidding), do: "Bidding"
  def label(:discard), do: "Discard"
  def label(:playing), do: "Playing"
  def label(:scoring), do: "Scoring"
  def label(:final_scoring), do: "Final Scoring"
end
