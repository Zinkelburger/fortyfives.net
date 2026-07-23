defmodule Website45sV3.Game.GameSupervisorTest do
  # Mutates global application env, so must not run alongside other tests.
  use ExUnit.Case, async: false

  alias Website45sV3.Game.GameSupervisor

  test "start_game refuses new games at the concurrent-game cap" do
    Application.put_env(:website_45s_v3, :max_concurrent_games, 0)
    on_exit(fn -> Application.delete_env(:website_45s_v3, :max_concurrent_games) end)

    unique = System.unique_integer([:positive])
    players = for n <- 1..4, do: {"Player#{n}", "cap_user_#{n}_#{unique}"}

    assert {:error, :too_many_games} =
             GameSupervisor.start_game("cap_test_game_#{unique}", players)
  end
end
