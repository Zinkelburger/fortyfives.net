defmodule Website45sV3.Game.UnattendedGameTest do
  # Games here end for real, so their GameLog rows need the shared sandbox.
  use Website45sV3.DataCase, async: false

  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.GameLog

  setup do
    previous = Application.get_env(:website_45s_v3, :game_timings, [])

    Application.put_env(
      :website_45s_v3,
      :game_timings,
      Keyword.merge(previous, unattended_timeout: 100)
    )

    on_exit(fn -> Application.put_env(:website_45s_v3, :game_timings, previous) end)
  end

  defp start_game(players) do
    game_name = "unattended_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, pid} = GameController.start_link({game_name, players})
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {game_name, pid, Process.monitor(pid)}
  end

  defp solo_game do
    n = System.unique_integer([:positive])
    human = "solo_#{n}"
    players = [{"Me", human}, {"Ann", "bot_#{n}_a"}, {"Ben", "bot_#{n}_b"}, {"Cat", "bot_#{n}_c"}]
    {game_name, pid, ref} = start_game(players)
    {human, game_name, pid, ref}
  end

  defp presence(pid, joins, leaves) do
    send(pid, %Phoenix.Socket.Broadcast{
      topic: "game",
      event: "presence_diff",
      payload: %{
        joins: Map.new(joins, &{&1, %{metas: []}}),
        leaves: Map.new(leaves, &{&1, %{metas: []}})
      }
    })

    _sync = GameController.get_game_state(pid)
  end

  test "abandoning the only human seat ends the game at once and logs it as abandoned" do
    {human, game_name, pid, ref} = solo_game()
    presence(pid, [human], [])

    send(pid, {:abandon_game, human})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    assert %GameLog{ended: "abandoned"} = Repo.get_by(GameLog, game_name: game_name)
  end

  test "a game whose only human disconnects ends after the grace period" do
    {human, game_name, pid, ref} = solo_game()
    presence(pid, [human], [])

    presence(pid, [], [human])

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    assert %GameLog{ended: "abandoned"} = Repo.get_by(GameLog, game_name: game_name)
  end

  test "reconnecting within the grace period keeps the game going" do
    {human, _game_name, pid, ref} = solo_game()
    presence(pid, [human], [])

    presence(pid, [], [human])
    presence(pid, [human], [])

    refute_receive {:DOWN, ^ref, _, _, _}, 300
    assert GameController.get_game_state(pid).unattended_timer == nil
  end

  test "one human leaving a table of humans leaves the game running" do
    n = System.unique_integer([:positive])
    [quitter | stayers] = humans = for i <- 1..4, do: "multi_#{n}_#{i}"
    {_game_name, pid, ref} = start_game(Enum.map(humans, &{&1, &1}))
    presence(pid, humans, [])

    send(pid, {:abandon_game, quitter})
    presence(pid, [], [quitter])

    refute_receive {:DOWN, ^ref, _, _, _}, 300
    state = GameController.get_game_state(pid)
    assert Enum.all?(stayers, &(&1 in state.active_players))
  end

  test "games seated entirely by bots are left to the all-bot timeout" do
    n = System.unique_integer([:positive])
    {_game_name, pid, ref} = start_game(for i <- 1..4, do: {"Bot#{i}", "bot_#{n}_#{i}"})

    refute_receive {:DOWN, ^ref, _, _, _}, 300
    assert GameController.get_game_state(pid).unattended_timer == nil
  end
end
