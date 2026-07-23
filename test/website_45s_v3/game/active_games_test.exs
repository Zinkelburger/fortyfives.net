defmodule Website45sV3.Game.ActiveGamesTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.ActiveGames

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp fake_game_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  test "registers human players and ignores bot seats" do
    game = unique("ag_game_")
    human = unique("ag_user_")
    bot = "bot_" <> unique("")

    :ok = ActiveGames.register_game(fake_game_process(), game, [human, bot])

    assert ActiveGames.find_game(human) == game
    assert ActiveGames.find_game(bot) == nil
  end

  test "entries are cleaned up when the game process exits" do
    game = unique("ag_game_")
    human = unique("ag_user_")
    pid = fake_game_process()

    :ok = ActiveGames.register_game(pid, game, [human])
    assert ActiveGames.find_game(human) == game

    Process.exit(pid, :kill)
    wait_until(fn -> ActiveGames.find_game(human) == nil end)
  end

  test "remove_player frees only that seat" do
    game = unique("ag_game_")
    [a, b] = [unique("ag_user_"), unique("ag_user_")]

    :ok = ActiveGames.register_game(fake_game_process(), game, [a, b])
    :ok = ActiveGames.remove_player(a)

    assert ActiveGames.find_game(a) == nil
    assert ActiveGames.find_game(b) == game
  end

  test "a newer game's entry survives the old game's exit" do
    user = unique("ag_user_")
    sentinel = unique("ag_user_")
    old_game = unique("ag_game_")
    new_game = unique("ag_game_")
    old_pid = fake_game_process()

    :ok = ActiveGames.register_game(old_pid, old_game, [user, sentinel])
    # The user abandons the old game and is seated in a new one.
    :ok = ActiveGames.remove_player(user)
    :ok = ActiveGames.register_game(fake_game_process(), new_game, [user])

    Process.exit(old_pid, :kill)

    # The sentinel going away proves the old game's DOWN cleanup ran; it must
    # not have clobbered the user's newer seat.
    wait_until(fn -> ActiveGames.find_game(sentinel) == nil end)
    assert ActiveGames.find_game(user) == new_game
  end
end
