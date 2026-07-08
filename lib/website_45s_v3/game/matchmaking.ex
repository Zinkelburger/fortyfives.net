defmodule Website45sV3.Game.Matchmaking do
  @moduledoc """
  Helpers shared by the public queue and private lobby managers: display-name
  assignment for anonymous players, game-name generation, and starting games.
  """
  require Logger

  @doc """
  Assigns a display name to a joining player. Anonymous players get a unique
  `AnonymousN` name based on the players already in the queue.
  """
  def assign_display_name(incoming_name, players) do
    if String.trim(incoming_name) in ["", "Anonymous"] do
      assign_anonymous_name(players)
    else
      incoming_name
    end
  end

  defp assign_anonymous_name(players) do
    anonymous_numbers =
      players
      |> Enum.flat_map(fn {name, _id} ->
        case Regex.run(~r/^Anonymous(\d+)$/, name) do
          [_, num] -> [String.to_integer(num)]
          _ -> []
        end
      end)

    next_anonymous_number =
      case anonymous_numbers do
        [] -> 1
        _ -> Enum.max(anonymous_numbers) + 1
      end

    "Anonymous#{next_anonymous_number}"
  end

  @doc """
  Starts a game for the given `{name, user_id}` players and redirects them to
  it. Returns `:ok`, or `{:error, reason}` if the game could not be started
  (in which case no players were redirected).
  """
  def start_game(players) do
    game_name = create_unique_game_name()

    case Website45sV3.Game.GameController.start_game(game_name, players) do
      {:ok, _pid} ->
        for {_name, user_id} <- players do
          Phoenix.PubSub.broadcast(
            Website45sV3.PubSub,
            "user:#{user_id}",
            {:redirect, "/game/#{game_name}"}
          )
        end

        :ok

      {:error, reason} ->
        Logger.error("Failed to start game #{game_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generates a random 12-character game name that is not currently registered.
  """
  def create_unique_game_name do
    game_name = generate_game_name()

    case Registry.lookup(Website45sV3.Registry, game_name) do
      [] -> game_name
      _other -> create_unique_game_name()
    end
  end

  defp generate_game_name do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16()
    |> String.slice(0, 12)
  end
end
