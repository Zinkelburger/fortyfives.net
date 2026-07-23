defmodule Website45sV3.Game.ActiveGames do
  @moduledoc """
  Tracks which running game each human player is seated in.

  This is what lets the lobby offer "rejoin your game" instead of a fresh
  queue, and what enforces one game per session (a real resource limit,
  unlike a click cooldown). Entries are written when a game starts, removed
  when a player abandons their seat, and cleaned up automatically via a
  monitor when the game process exits for any reason.

  Lookups read a public ETS table directly, so `find_game/1` never blocks
  on this GenServer.
  """
  use GenServer

  @table __MODULE__

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Registers every human player of `game_name` as seated in that game.
  Bot ids (`"bot_" <> _`) are ignored. Called from the game process itself
  so the entries exist before any player is redirected to the game.
  """
  def register_game(game_pid, game_name, player_ids) do
    human_ids = Enum.reject(player_ids, &String.starts_with?(&1, "bot_"))
    GenServer.call(__MODULE__, {:register_game, game_pid, game_name, human_ids})
  end

  @doc "Returns the game the user is currently seated in, or `nil`."
  def find_game(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, game_name}] -> game_name
      [] -> nil
    end
  end

  @doc "Frees a player's seat record (they abandoned the game)."
  def remove_player(user_id) do
    GenServer.call(__MODULE__, {:remove_player, user_id})
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # games: monitor ref => {game_name, player_ids} so a game's exit removes
    # exactly the entries it created.
    {:ok, %{games: %{}}}
  end

  @impl true
  def handle_call({:register_game, game_pid, game_name, player_ids}, _from, state) do
    ref = Process.monitor(game_pid)
    :ets.insert(@table, Enum.map(player_ids, &{&1, game_name}))
    {:reply, :ok, put_in(state.games[ref], {game_name, player_ids})}
  end

  def handle_call({:remove_player, user_id}, _from, state) do
    :ets.delete(@table, user_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {entry, games} = Map.pop(state.games, ref)

    with {game_name, player_ids} <- entry do
      # delete_object only removes entries still pointing at this game, so a
      # player who already moved on to a newer game keeps their new entry.
      Enum.each(player_ids, &:ets.delete_object(@table, {&1, game_name}))
    end

    {:noreply, %{state | games: games}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
