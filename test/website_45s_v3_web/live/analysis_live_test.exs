defmodule Website45sV3Web.AnalysisLiveTest do
  use Website45sV3Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Website45sV3.Analysis.Cards
  alias Website45sV3.Analysis.Codec
  alias Website45sV3.Analysis.Codec.Settings
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Engine.Setup
  alias Website45sV3.Analysis.Variant

  defp start(view, params) do
    view
    |> form("#setup-form", game: params)
    |> render_submit()

    assert_patch(view)
  end

  defp game_url(variant, actions \\ [], settings \\ %Settings{}) do
    v = Variant.get!(variant)
    setup = %Setup{variant: v, seed: 31, dealer: v.n - 1}
    "/analysis?g=" <> Codec.encode(setup, settings, actions)
  end

  test "the setup screen offers every variant and both modes", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/analysis")
    assert html =~ "Partners"
    for n <- 2..6, do: assert(html =~ "Cutthroat #{n}")
    assert html =~ "Analysis"
    assert html =~ "Play"
    refute html =~ ~s(<nav aria-label="Main")
    assert has_element?(view, "#start-button")
  end

  test "dealing starts a game whose link holds it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/analysis")
    path = start(view, %{variant: "ct3", mode: "play", opponents: "site", dealer: "me"})
    assert path =~ "/analysis?g="
    assert render(view) =~ "Bidding"
    # Play mode: no hints or panel.
    refute has_element?(view, ".board-rail")
  end

  test "a partners game can be played to the end against site bots", %{conn: conn} do
    {:ok, view, _html} = live(conn, game_url("team4", [], %Settings{mode: :play}))
    play_out(view, 400)
    html = render(view)
    assert html =~ "Game over"
    # The review opens once the game is over.
    assert has_element?(view, ".board-rail")
    assert has_element?(view, "#move-list")
  end

  test "cutthroat for six seats plays with every seat on the table", %{conn: conn} do
    {:ok, view, _html} = live(conn, game_url("ct6", [], %Settings{mode: :play}))
    html = render(view)
    for p <- 1..5, do: assert(html =~ "Bot #{p}")
    play_out(view, 25)
    assert render(view) =~ ~r/Hand results|Game over|Playing|Discard/
  end

  test "a game link reopens the same position and steps back", %{conn: conn} do
    {:ok, view, _} = live(conn, game_url("ct2"))
    play_out(view, 6)
    path = last_patch(view)
    assert path =~ "/analysis?g="
    {:ok, view2, _} = live(conn, path)
    assert render(view2) =~ "Playing" or render(view2) =~ "Discard" or render(view2) =~ "Bidding"
    render_click(view2, "nav", %{"to" => "start"})
    assert render(view2) =~ "Move 0 of"
    render_click(view2, "nav", %{"to" => "end"})
    refute render(view2) =~ "Move 0 of"
  end

  test "the deal editor deals the chosen cards", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/analysis")

    render_click(view, "setup_deal", %{
      "game" => %{
        "variant" => "team4",
        "mode" => "analysis",
        "opponents" => "site",
        "dealer" => "me"
      }
    })

    assert has_element?(view, ".editor")

    # Four fives and the ace of hearts for you.
    for card <- [Cards.id(0, 1), Cards.id(0, 5), Cards.id(1, 5), Cards.id(2, 5), Cards.id(3, 5)] do
      render_click(view, "editor_card", %{"card" => Integer.to_string(card)})
    end

    view
    |> form("#editor-form", editor: %{dealer: "3", score_0: "100", score_1: "110"})
    |> render_change()

    view |> form("#editor-form") |> render_submit()
    path = assert_patch(view)

    {:ok, setup, _, []} =
      path
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()
      |> Map.fetch!("g")
      |> Codec.decode()

    assert setup.scores == [100, 110]
    assert setup.dealer == 3
    assert Enum.sort(Engine.new(setup).dealt[0]) == Enum.sort([0, 4, 17, 30, 43])
    html = render(view)
    assert html =~ "100"
    assert html =~ "110"
  end

  # Makes your moves (pass, keep the first card, play the first legal card)
  # until the game ends or `limit` moves were made.
  defp play_out(view, 0), do: view

  defp play_out(view, limit) do
    html = render(view)

    cond do
      html =~ "Game over" ->
        view

      has_element?(view, "#next-hand-button") ->
        render_click(view, "next_hand", %{})
        play_out(view, limit - 1)

      html =~ "Bagged · choose trump" ->
        render_click(view, "set_bid_suit", %{"bid-suit" => "hearts"})
        render_click(view, "confirm_bid", %{})
        play_out(view, limit - 1)

      html =~ "Your bid" ->
        render_click(view, "set_bid_pass", %{})
        render_click(view, "confirm_bid", %{})
        play_out(view, limit - 1)

      html =~ "Your keep" ->
        [card | _] = cards(view, :any)
        render_click(view, "confirm_discard", %{"cards" => [card]})
        play_out(view, limit - 1)

      html =~ "Your turn" ->
        [card | _] = cards(view, :enabled)
        render_click(view, "play-card", %{"cards" => [card]})
        play_out(view, limit - 1)

      true ->
        # A bot is to move: let its timer fire.
        Process.sleep(5)
        play_out(view, limit - 1)
    end
  end

  defp cards(view, selector) do
    html = view |> element("#player-hand") |> render()

    ~r/<button[^>]*data-card="([^"]+)"[^>]*>/
    |> Regex.scan(html)
    |> Enum.filter(fn [tag, _] -> selector == :any or not String.contains?(tag, " disabled") end)
    |> Enum.map(fn [_, card] -> card end)
  end

  # The newest path the view patched to.
  defp last_patch(view, last \\ nil) do
    last_patch(view, assert_patch(view, 100))
  rescue
    _ in [ExUnit.AssertionError, ArgumentError] -> last
  end
end
