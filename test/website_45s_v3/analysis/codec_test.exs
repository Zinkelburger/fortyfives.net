defmodule Website45sV3.Analysis.CodecTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Analysis.Advisor
  alias Website45sV3.Analysis.Codec
  alias Website45sV3.Analysis.Codec.Settings
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Engine.Setup
  alias Website45sV3.Analysis.Variant

  # A whole game between site bots: every seat's move until someone wins.
  defp bot_game(setup, limit \\ 2000) do
    Stream.iterate({Engine.new(setup), []}, fn {state, actions} ->
      action =
        case Engine.to_act(state) do
          [seat | _] -> Advisor.move(state, seat, :site)
          [] -> :next_hand
        end

      {:ok, next} = Engine.apply_action(state, action)
      {next, [action | actions]}
    end)
    |> Enum.find(fn {state, actions} -> state.phase == :game_over or length(actions) > limit end)
    |> then(fn {state, actions} -> {state, Enum.reverse(actions)} end)
  end

  for id <- Variant.ids() do
    @id id
    test "#{id}: a whole game survives encoding" do
      setup = %Setup{variant: Variant.get!(@id), seed: 4242, dealer: 1}
      {final, actions} = bot_game(setup)
      assert final.phase == :game_over

      settings = %Settings{mode: :play, opponents: :strong, partner: :site}
      code = Codec.encode(setup, settings, actions)
      assert byte_size(code) < 2000

      assert {:ok, decoded, ^settings, ^actions} = Codec.decode(code)
      assert decoded.variant == setup.variant
      assert {:ok, %{phase: :game_over, scores: scores}} = Engine.replay(decoded, actions)
      assert scores == final.scores
    end
  end

  test "chosen deals, scores and dealer are kept" do
    variant = Variant.get!("ct6")
    deck = Enum.shuffle(0..51)

    setup = %Setup{
      variant: variant,
      seed: 7,
      dealer: 4,
      scores: [100, -20, 5, 0, 115, 30],
      decks: %{1 => deck}
    }

    code = Codec.encode(setup, %Settings{}, [])
    assert {:ok, ^setup, %Settings{mode: :analysis}, []} = Codec.decode(code)
    assert Engine.new(setup).dealt[0] == Enum.take(deck, 5)
  end

  test "the same seed always deals the same cards" do
    assert Engine.shuffle(99, 3) == Engine.shuffle(99, 3)
    refute Engine.shuffle(99, 3) == Engine.shuffle(99, 4)
    assert Enum.sort(Engine.shuffle(1, 1)) == Enum.to_list(0..51)
  end

  test "a damaged link opens as far as it is good, or not at all" do
    setup = %Setup{variant: Variant.get!("team4"), seed: 11, dealer: 0}
    {_, actions} = bot_game(setup)
    code = Codec.encode(setup, %Settings{}, actions)
    {:ok, bin} = Base.url_decode64(code, padding: false)

    # Cut off mid-game: the moves up to the cut are kept.
    cut = Base.url_encode64(binary_part(bin, 0, byte_size(bin) - 7), padding: false)
    assert {:ok, _, _, partial} = Codec.decode(cut)
    assert partial == Enum.take(actions, length(partial))

    assert Codec.decode("not a game") == :error
    assert Codec.decode(Base.url_encode64(<<9, 0, 0, 0>>, padding: false)) == :error

    assert Codec.decode(Base.url_encode64(<<1, 77, 0, 0, 0, 0, 0, 0, 2>>, padding: false)) ==
             :error
  end
end
