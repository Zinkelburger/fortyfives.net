defmodule Website45sV3.Analysis.Codec do
  @moduledoc """
  A whole analysis-board game in one URL parameter, so a game survives a
  reload and can be shared: the setup, the board's settings and every move,
  packed into bytes and Base64url-encoded (a 10-hand game is well under 1 KB).

  Layout (version 1):

      <<1, variant, dealer, mode_and_bots, seed::32, scores..., decks..., moves...>>

  Moves are one byte each and read against the replayed game: a bid is
  `0` for pass or `1 + 4 · (value / 5 - 3) + suit`, a play is the card id, a
  keep is the seat then a bit mask over the seat's cards as dealt, and 255
  starts the next hand.
  """
  import Bitwise
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Engine.Setup
  alias Website45sV3.Analysis.Variant

  @version 1
  @next 255

  defmodule Settings do
    @moduledoc "How the board is played: hints on or off, and how strong the bots are."
    defstruct mode: :analysis, opponents: :site, partner: :site

    @type t :: %__MODULE__{
            mode: :analysis | :play,
            opponents: :site | :strong,
            partner: :site | :strong
          }
  end

  def encode(%Setup{} = setup, %Settings{} = settings, actions) do
    variant_index = Enum.find_index(Variant.ids(), &(&1 == setup.variant.id))
    scores = setup.scores || List.duplicate(0, Variant.sides(setup.variant))

    flags =
      if(settings.mode == :play, do: 1, else: 0) |||
        if(settings.opponents == :strong, do: 2, else: 0) |||
        if(settings.partner == :strong, do: 4, else: 0)

    decks =
      setup.decks
      |> Enum.sort()
      |> Enum.map(fn {hand, deck} -> <<hand, :erlang.list_to_binary(deck)::binary>> end)

    {:ok, moves} = encode_moves(setup, actions)

    IO.iodata_to_binary([
      <<@version, variant_index, setup.dealer, flags, setup.seed::32, length(scores)>>,
      Enum.map(scores, &<<&1::signed-16>>),
      <<length(decks)>>,
      decks,
      moves
    ])
    |> Base.url_encode64(padding: false)
  end

  defp encode_moves(setup, actions) do
    state = Engine.new(setup)

    Enum.reduce_while(actions, {:ok, state, []}, fn action, {:ok, state, acc} ->
      bytes = action_bytes(state, action)

      case Engine.apply_action(state, action) do
        {:ok, next} -> {:cont, {:ok, next, [acc, bytes]}}
        {:error, _} -> {:halt, {:ok, state, acc}}
      end
    end)
    |> then(fn {:ok, _state, acc} -> {:ok, IO.iodata_to_binary(acc)} end)
  end

  defp action_bytes(_state, {:bid, _seat, {0, nil}}), do: <<0>>
  defp action_bytes(_state, {:bid, _seat, {v, s}}), do: <<1 + 4 * (div(v, 5) - 3) + s>>
  defp action_bytes(_state, {:play, _seat, card}), do: <<card>>
  defp action_bytes(_state, :next_hand), do: <<@next>>

  defp action_bytes(state, {:keep, seat, kept}) do
    mask =
      state.hands[seat]
      |> Enum.with_index()
      |> Enum.reduce(0, fn {c, i}, m -> if c in kept, do: m ||| 1 <<< i, else: m end)

    <<seat, mask>>
  end

  @doc "`{:ok, setup, settings, actions}` from an encoded game, or `:error`."
  def decode(string) when is_binary(string) and byte_size(string) < 8192 do
    with {:ok, bin} <- Base.url_decode64(string, padding: false),
         <<@version, vi, dealer, flags, seed::32, ns, rest::binary>> <- bin,
         id when is_binary(id) <- Enum.at(Variant.ids(), vi),
         variant = Variant.get!(id),
         true <- dealer < variant.n and ns == Variant.sides(variant),
         {:ok, scores, rest} <- take_scores(rest, ns, []),
         <<nd, rest::binary>> <- rest,
         {:ok, decks, moves} <- take_decks(rest, nd, %{}) do
      setup = %Setup{variant: variant, seed: seed, dealer: dealer, scores: scores, decks: decks}

      settings = %Settings{
        mode: if(band(flags, 1) == 1, do: :play, else: :analysis),
        opponents: if(band(flags, 2) == 2, do: :strong, else: :site),
        partner: if(band(flags, 4) == 4, do: :strong, else: :site)
      }

      {:ok, setup, settings, decode_moves(Engine.new(setup), moves, [])}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp take_scores(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_scores(<<s::signed-16, rest::binary>>, n, acc) when s in -999..999,
    do: take_scores(rest, n - 1, [s | acc])

  defp take_scores(_, _, _), do: :error

  defp take_decks(rest, 0, acc), do: {:ok, acc, rest}

  defp take_decks(<<hand, deck::binary-size(52), rest::binary>>, n, acc) do
    cards = :erlang.binary_to_list(deck)

    if hand >= 1 and Enum.sort(cards) == Enum.to_list(0..51),
      do: take_decks(rest, n - 1, Map.put(acc, hand, cards)),
      else: :error
  end

  defp take_decks(_, _, _), do: :error

  # Moves that don't fit the replayed game end the list: a damaged link
  # still opens the game as far as it goes.
  defp decode_moves(_state, <<>>, acc), do: Enum.reverse(acc)

  defp decode_moves(state, bin, acc) do
    with {:ok, action, rest} <- read_action(state, bin),
         {:ok, next} <- Engine.apply_action(state, action) do
      decode_moves(next, rest, [action | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp read_action(%{phase: :hand_over}, <<@next, rest::binary>>), do: {:ok, :next_hand, rest}

  defp read_action(%{phase: :bidding} = s, <<b, rest::binary>>) do
    [seat] = Engine.to_act(s)
    bid = if b == 0, do: {0, nil}, else: {(div(b - 1, 4) + 3) * 5, rem(b - 1, 4)}
    {:ok, {:bid, seat, bid}, rest}
  end

  defp read_action(%{phase: :discard} = s, <<seat, mask, rest::binary>>) do
    case s.hands[seat] do
      hand when is_list(hand) ->
        kept = for {c, i} <- Enum.with_index(hand), band(mask, 1 <<< i) != 0, do: c
        {:ok, {:keep, seat, kept}, rest}

      _ ->
        :error
    end
  end

  defp read_action(%{phase: :playing} = s, <<card, rest::binary>>) do
    [seat] = Engine.to_act(s)
    {:ok, {:play, seat, card}, rest}
  end

  defp read_action(_, _), do: :error
end
