defmodule Website45sV3.Game.StateTest do
  use ExUnit.Case

  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.Phase
  alias Website45sV3.Game.State

  @players [{"Ann", "human_1"}, {"Bot1", "bot_1"}, {"Cy", "human_2"}, {"Bot2", "bot_2"}]

  # Killed rather than stopped: a stopped game writes its log to the database.
  defp running_game_state do
    name = "state_test_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, pid} = GameController.start_link({name, @players})
    state = GameController.get_game_state(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    state
  end

  test "a running game holds a complete State, starting in bidding" do
    state = running_game_state()

    assert %State{phase: :bidding, queue: "public"} = state
    assert state |> Map.from_struct() |> map_size() == 41
  end

  test "a state with a missing or misspelled field is refused" do
    fields = Map.from_struct(running_game_state())

    assert %State{} = State.new(fields)
    assert_raise ArgumentError, fn -> State.new(Map.delete(fields, :phase)) end
    assert_raise KeyError, fn -> State.new(Map.put(fields, :pahse, :bidding)) end
  end

  test "every phase has the label the browser and the event log use" do
    assert Enum.map(Phase.all(), &Phase.label/1) ==
             ["Bidding", "Discard", "Playing", "Scoring", "Final Scoring"]
  end
end
