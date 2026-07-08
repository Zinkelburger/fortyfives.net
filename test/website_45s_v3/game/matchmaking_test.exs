defmodule Website45sV3.Game.MatchmakingTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.Matchmaking

  describe "create_unique_game_name/0" do
    test "generates 12-character names with real entropy" do
      names = for _ <- 1..500, do: Matchmaking.create_unique_game_name()

      assert Enum.all?(names, &(String.length(&1) == 12))
      # With 48 bits of entropy 500 draws must not collide; the old
      # implementation only had 63 possible names in total.
      assert length(Enum.uniq(names)) == 500
    end
  end

  describe "assign_display_name/2" do
    test "keeps a real display name" do
      assert Matchmaking.assign_display_name("Andrew", []) == "Andrew"
    end

    test "numbers anonymous players uniquely" do
      assert Matchmaking.assign_display_name("Anonymous", []) == "Anonymous1"

      players = [{"Anonymous1", "a"}, {"Anonymous3", "b"}, {"Pat", "c"}]
      assert Matchmaking.assign_display_name("", players) == "Anonymous4"
      assert Matchmaking.assign_display_name("  ", players) == "Anonymous4"
    end
  end
end
