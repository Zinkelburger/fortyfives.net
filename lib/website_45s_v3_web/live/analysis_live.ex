defmodule Website45sV3Web.AnalysisLive do
  @moduledoc """
  The analysis board: play any variant against the bots on the familiar
  table, with the trained network's value for every choice (Analysis), or
  without hints until the game is over (Play). Step back through the game,
  try another card, set up any deal, and review every decision afterwards.

  The whole game lives in the URL (`?g=`, see `Website45sV3.Analysis.Codec`),
  so a reload resumes it and a link shares it. Nothing is stored on the server.
  """
  use Website45sV3Web, :live_view

  import Website45sV3Web.AnalysisComponents

  alias Website45sV3.Analysis.Advisor
  alias Website45sV3.Analysis.Cards
  alias Website45sV3.Analysis.Codec
  alias Website45sV3.Analysis.Codec.Settings
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Engine.Setup
  alias Website45sV3.Analysis.Variant

  @me 0

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Analysis | Forty Fives",
       code: nil,
       setup: nil,
       settings: %Settings{},
       actions: [],
       cursor: 0,
       state: nil,
       mainline: nil,
       control_all: false,
       reveal: false,
       options: nil,
       options_key: nil,
       judgments: %{},
       judged_upto: 0,
       selected_bid: nil,
       selected_suit: nil,
       bid_error: nil,
       dialog: nil,
       editor: nil,
       bot_token: nil,
       finished: false,
       form: default_form()
     )}
  end

  defp default_form,
    do: %{"variant" => "team4", "mode" => "analysis", "opponents" => "site", "dealer" => "random"}

  @impl true
  def handle_params(%{"g" => code} = params, _uri, socket) do
    if code == socket.assigns.code do
      {:noreply, socket}
    else
      case Codec.decode(code) do
        {:ok, setup, settings, actions} ->
          cursor = cursor_param(params["at"], length(actions))

          {:noreply,
           socket
           |> assign(
             code: code,
             setup: setup,
             settings: settings,
             actions: actions,
             mainline: nil
           )
           |> assign(judgments: %{}, judged_upto: 0, options: nil, options_key: nil)
           |> assign(finished: finished?(setup, actions))
           |> goto(cursor)}

        :error ->
          {:noreply,
           socket
           |> put_flash(:error, "That game link is damaged.")
           |> push_patch(to: ~p"/analysis")}
      end
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket, code: nil, setup: nil, state: nil, actions: [], cursor: 0, dialog: nil)}
  end

  defp cursor_param(nil, len), do: len

  defp cursor_param(at, len) do
    case Integer.parse(at) do
      {n, ""} -> min(max(n, 0), len)
      _ -> len
    end
  end

  ## Positions

  # Shows the position after the first `cursor` moves.
  defp goto(socket, cursor) do
    %{setup: setup, actions: actions} = socket.assigns
    {:ok, state} = Engine.replay(setup, Enum.take(actions, cursor))

    socket
    |> assign(state: state, cursor: cursor, selected_bid: nil, selected_suit: nil, bid_error: nil)
    |> refresh()
  end

  defp live?(assigns), do: assigns.cursor == length(assigns.actions)

  # Everything that follows from a new position: hints, review, bot moves.
  defp refresh(socket) do
    socket
    |> request_options()
    |> request_review()
    |> schedule_bot()
  end

  defp push_game(socket) do
    %{setup: setup, settings: settings, actions: actions} = socket.assigns
    code = Codec.encode(setup, settings, actions)
    at = if live?(socket.assigns), do: [], else: [at: socket.assigns.cursor]

    socket
    |> assign(code: code)
    |> push_patch(to: ~p"/analysis?#{[g: code] ++ at}", replace: true)
  end

  # A move at the current position. Moving from an earlier position starts a
  # new line from there; the game as played is kept to return to.
  defp play(socket, action) do
    %{actions: actions, cursor: cursor, state: state} = socket.assigns

    case Engine.apply_action(state, action) do
      {:ok, next} ->
        # Replaying the game's own next move keeps the line as it is.
        {actions, mainline} =
          if Enum.at(actions, cursor) == action,
            do: {actions, socket.assigns.mainline},
            else: branch(actions, cursor, action, socket.assigns.mainline)

        socket
        |> assign(actions: actions, mainline: mainline, state: next, cursor: cursor + 1)
        |> assign(finished: socket.assigns.finished or next.phase == :game_over)
        |> assign(selected_bid: nil, selected_suit: nil, bid_error: nil)
        |> assign(judged_upto: min(socket.assigns.judged_upto, cursor))
        |> refresh()
        |> push_game()

      {:error, _} ->
        socket
    end
  end

  defp branch(actions, cursor, action, mainline) when cursor == length(actions),
    do: {actions ++ [action], mainline}

  defp branch(actions, cursor, action, mainline),
    do: {Enum.take(actions, cursor) ++ [action], mainline || actions}

  ## Seats

  # Who the board plays for: you, or every seat when "Move for every seat" is on.
  defp human?(assigns, seat), do: seat == @me or assigns.control_all

  # The seat whose hand is in the hand panel.
  def hand_seat(assigns) do
    if assigns.control_all, do: focus_seat(assigns) || @me, else: @me
  end

  # The seat whose decision the hints are about: the next move of the line
  # when looking back, otherwise the seat at the board.
  def focus_seat(%{state: nil}), do: nil

  def focus_seat(assigns) do
    case Enum.at(assigns.actions, assigns.cursor) do
      {_kind, seat, _} ->
        seat

      _ ->
        acting = Engine.to_act(assigns.state)

        cond do
          @me in acting and not assigns.control_all -> @me
          assigns.control_all -> List.first(acting)
          true -> nil
        end
    end
  end

  @doc false
  def hints?(%{settings: %{mode: :analysis}}), do: true
  def hints?(%{finished: true}), do: true
  def hints?(_), do: false

  defp finished?(setup, actions) do
    match?({:ok, %{phase: :game_over}}, Engine.replay(setup, actions))
  end

  # Hints for a bot's decision would show its cards; only with "Show all
  # hands", or when you move for every seat.
  def show_options?(assigns) do
    seat = focus_seat(assigns)
    hints?(assigns) and seat != nil and (seat == @me or assigns.reveal or assigns.control_all)
  end

  ## Hints (async: valuing every keep can take a moment)

  defp request_options(socket) do
    a = socket.assigns
    seat = focus_seat(a)
    key = {a.code, a.cursor, seat, length(a.actions)}

    cond do
      not show_options?(a) ->
        assign(socket, options: nil, options_key: nil)

      a.options_key == key ->
        socket

      true ->
        state = a.state

        socket
        |> assign(options_key: key, options: :loading)
        |> start_async(:options, fn -> {key, Advisor.options(state, seat)} end)
    end
  end

  # Judges every decision you made in the line, for the move list and graph.
  defp request_review(socket) do
    a = socket.assigns
    len = length(a.actions)

    if hints?(a) and a.judged_upto < len do
      %{setup: setup, actions: actions, judged_upto: from} = a
      judgments = Map.reject(a.judgments, fn {i, _} -> i >= from end)
      control_all = a.control_all

      socket
      |> assign(judgments: judgments, judged_upto: len)
      |> start_async(:review, fn -> {actions, judge_line(setup, actions, from, control_all)} end)
    else
      socket
    end
  end

  defp judge_line(setup, actions, from, control_all) do
    {:ok, state} = Engine.replay(setup, Enum.take(actions, from))

    actions
    |> Enum.drop(from)
    |> Enum.with_index(from)
    |> Enum.reduce({state, %{}}, fn {action, i}, {state, acc} ->
      acc = judge_action(state, action, i, acc, control_all)
      {:ok, next} = Engine.apply_action(state, action)
      {next, acc}
    end)
    |> elem(1)
  end

  defp judge_action(state, {_kind, seat, _} = action, i, acc, control_all)
       when seat == @me or control_all do
    case Advisor.judge(Advisor.options(state, seat), action) do
      nil -> acc
      judged -> Map.put(acc, i, judged)
    end
  end

  defp judge_action(_state, _action, _i, acc, _control_all), do: acc

  @impl true
  def handle_async(:options, {:ok, {key, options}}, socket) do
    if key == socket.assigns.options_key,
      do: {:noreply, assign(socket, options: options)},
      else: {:noreply, socket}
  end

  def handle_async(:review, {:ok, {actions, judged}}, socket) do
    if List.starts_with?(socket.assigns.actions, Enum.take(actions, socket.assigns.judged_upto)) do
      {:noreply, assign(socket, judgments: Map.merge(socket.assigns.judgments, judged))}
    else
      {:noreply, socket}
    end
  end

  def handle_async(_name, {:exit, _reason}, socket), do: {:noreply, socket}

  ## Bots

  defp schedule_bot(socket) do
    a = socket.assigns

    with true <- a.state != nil and live?(a),
         [seat | _] <- Enum.reject(Engine.to_act(a.state), &human?(a, &1)) do
      token = make_ref()
      Process.send_after(self(), {:bot, token, seat}, bot_delay(a.state))
      assign(socket, bot_token: token)
    else
      _ -> assign(socket, bot_token: nil)
    end
  end

  # Pauses so a bot's card can be seen, longer after a trick so it can be
  # read. Tests set them to zero (config :website_45s_v3, :analysis_delays).
  defp bot_delay(state) do
    delays =
      Application.get_env(:website_45s_v3, :analysis_delays, %{move: 550, trick: 1100, keep: 250})

    case state do
      %{phase: :discard} -> delays.keep
      %{last_trick: {_, _}, trick: []} -> delays.trick
      _ -> delays.move
    end
  end

  @impl true
  def handle_info({:bot, token, seat}, %{assigns: %{bot_token: token}} = socket) do
    a = socket.assigns

    if live?(a) and seat in Engine.to_act(a.state) do
      strength =
        if a.setup.variant.teams and seat == 2, do: a.settings.partner, else: a.settings.opponents

      case Advisor.move(a.state, seat, strength) do
        nil -> {:noreply, socket}
        action -> {:noreply, play(socket, action)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events: starting a game

  @impl true
  def handle_event("setup_change", %{"game" => params}, socket) do
    {:noreply,
     assign(socket,
       form: Map.merge(socket.assigns.form, Map.take(params, Map.keys(default_form())))
     )}
  end

  def handle_event("start", %{"game" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    {:noreply, start_game(socket, form, %{})}
  end

  def handle_event("new_game", _params, socket) do
    form =
      if socket.assigns.setup do
        %{
          socket.assigns.form
          | "variant" => socket.assigns.setup.variant.id,
            "mode" => Atom.to_string(socket.assigns.settings.mode)
        }
      else
        socket.assigns.form
      end

    {:noreply, socket |> assign(form: form, dialog: nil) |> push_patch(to: ~p"/analysis")}
  end

  def handle_event("rematch", _params, socket) do
    %{setup: setup, settings: settings} = socket.assigns

    setup = %Setup{
      variant: setup.variant,
      seed: new_seed(),
      dealer: :rand.uniform(setup.variant.n) - 1
    }

    {:noreply,
     socket
     |> assign(
       setup: setup,
       settings: settings,
       actions: [],
       mainline: nil,
       finished: false,
       judgments: %{},
       judged_upto: 0,
       dialog: nil
     )
     |> goto(0)
     |> push_game()}
  end

  ## Events: moves

  def handle_event("play-card", %{"cards" => [value]}, socket) do
    with {:ok, card} <- Cards.parse(value),
         seat when seat != nil <- hand_seat_if_acting(socket.assigns) do
      {:noreply, play(socket, {:play, seat, card})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("play-card", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_discard", %{"cards" => values}, socket) when is_list(values) do
    cards =
      values
      |> Enum.map(&Cards.parse/1)
      |> Enum.flat_map(fn
        {:ok, c} -> [c]
        _ -> []
      end)

    case hand_seat_if_acting(socket.assigns) do
      nil -> {:noreply, socket}
      seat -> {:noreply, play(socket, {:keep, seat, cards})}
    end
  end

  def handle_event("confirm_discard", _params, socket), do: {:noreply, socket}

  # The hint list's rows play their move.
  def handle_event("play_option", %{"i" => i}, socket) do
    with {i, ""} <- Integer.parse(i),
         options when is_list(options) <- socket.assigns.options,
         %{action: {_, seat, _} = action} <- Enum.at(options, i),
         true <- human?(socket.assigns, seat) or not live?(socket.assigns) do
      {:noreply, play(socket, action)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_bid_number", %{"bid-number" => bid}, socket)
      when bid in ["15", "20", "25", "30"] do
    suit = if socket.assigns.selected_suit == "pass", do: nil, else: socket.assigns.selected_suit
    {:noreply, assign(socket, selected_bid: bid, selected_suit: suit, bid_error: nil)}
  end

  def handle_event("set_bid_suit", %{"bid-suit" => suit}, socket)
      when suit in ["hearts", "diamonds", "clubs", "spades"] do
    bid = if socket.assigns.selected_bid == "0", do: nil, else: socket.assigns.selected_bid
    {:noreply, assign(socket, selected_bid: bid, selected_suit: suit, bid_error: nil)}
  end

  def handle_event("set_bid_pass", _params, socket) do
    {:noreply, assign(socket, selected_bid: "0", selected_suit: "pass", bid_error: nil)}
  end

  def handle_event("confirm_bid", _params, socket) do
    a = socket.assigns
    bagged = Engine.bagged?(a.state)

    bid =
      case {if(bagged, do: "15", else: a.selected_bid), a.selected_suit} do
        {"0", "pass"} ->
          {0, nil}

        {b, s} when is_binary(b) and s in ["hearts", "diamonds", "clubs", "spades"] ->
          {String.to_integer(b), Cards.suit_index(String.to_existing_atom(s))}

        _ ->
          nil
      end

    with seat when seat != nil <- hand_seat_if_acting(a),
         true <- bid in Engine.legal_bids(a.state) do
      {:noreply, play(socket, {:bid, seat, bid})}
    else
      _ ->
        {:noreply,
         assign(socket, bid_error: "Choose a bid higher than the current one, and a suit.")}
    end
  end

  def handle_event("next_hand", _params, socket) do
    if socket.assigns.state.phase == :hand_over,
      do: {:noreply, play(socket, :next_hand)},
      else: {:noreply, socket}
  end

  ## Events: moving through the game

  def handle_event("nav", %{"to" => to}, socket) do
    a = socket.assigns

    if a.state && (a.settings.mode == :analysis or a.finished) do
      len = length(a.actions)

      cursor =
        case to do
          "start" -> 0
          "back" -> max(a.cursor - 1, 0)
          "forward" -> min(a.cursor + 1, len)
          "end" -> len
          n -> min(max(String.to_integer(n), 0), len)
        end

      {:noreply, socket |> goto(cursor) |> push_game()}
    else
      {:noreply, socket}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("key", %{"key" => key}, socket) do
    to =
      %{"ArrowLeft" => "back", "ArrowRight" => "forward", "Home" => "start", "End" => "end"}[key]

    if to, do: handle_event("nav", %{"to" => to}, socket), else: {:noreply, socket}
  end

  def handle_event("back_to_game", _params, socket) do
    case socket.assigns.mainline do
      nil ->
        {:noreply, socket}

      mainline ->
        {:noreply,
         socket
         |> assign(
           actions: mainline,
           mainline: nil,
           finished: finished?(socket.assigns.setup, mainline),
           judgments: %{},
           judged_upto: 0
         )
         |> goto(length(mainline))
         |> push_game()}
    end
  end

  def handle_event("takeback", _params, socket) do
    a = socket.assigns

    if a.settings.mode == :analysis and a.actions != [] do
      # Back to your previous decision, dropping the bots' replies too.
      target =
        a.actions
        |> Enum.with_index()
        |> Enum.filter(fn {action, _} -> match?({_, @me, _}, action) end)
        |> List.last()

      cursor = if target, do: elem(target, 1), else: 0

      {:noreply,
       socket
       |> assign(actions: Enum.take(a.actions, cursor), judged_upto: min(a.judged_upto, cursor))
       |> goto(cursor)
       |> push_game()}
    else
      {:noreply, socket}
    end
  end

  ## Events: board settings

  def handle_event("toggle", %{"what" => what}, socket) when what in ["reveal", "control_all"] do
    key = String.to_existing_atom(what)

    if socket.assigns.settings.mode == :analysis do
      {:noreply,
       socket
       |> assign(key, not socket.assigns[key])
       |> assign(
         options_key: nil,
         judged_upto: if(key == :control_all, do: 0, else: socket.assigns.judged_upto)
       )
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_strength", %{"who" => who, "strength" => s}, socket)
      when who in ["opponents", "partner"] and s in ["site", "strong"] do
    settings =
      Map.put(socket.assigns.settings, String.to_existing_atom(who), String.to_existing_atom(s))

    {:noreply, socket |> assign(settings: settings) |> push_game()}
  end

  def handle_event("show_hints", _params, socket) do
    # Play mode keeps hints hidden; turning them on makes it an analysis game.
    settings = %{socket.assigns.settings | mode: :analysis}
    {:noreply, socket |> assign(settings: settings, options_key: nil) |> refresh() |> push_game()}
  end

  def handle_event("dialog", %{"open" => which}, socket)
      when which in ["scores", "rules", "menu"] do
    {:noreply, assign(socket, dialog: String.to_existing_atom(which))}
  end

  def handle_event(close, _params, socket) when close in ["close_dialog", "close_game_dialog"],
    do: {:noreply, assign(socket, dialog: nil, editor: nil)}

  ## Events: the deal editor

  def handle_event("edit_deal", _params, socket) do
    {:noreply, assign(socket, dialog: :editor, editor: editor_from(socket.assigns))}
  end

  def handle_event("editor_target", %{"target" => target}, socket) do
    editor = socket.assigns.editor
    target = if target == "kitty", do: :kitty, else: String.to_integer(target)

    if target == :kitty or target in 0..(editor.variant.n - 1),
      do: {:noreply, assign(socket, editor: %{editor | target: target})},
      else: {:noreply, socket}
  end

  def handle_event("editor_card", %{"card" => card}, socket) do
    card = String.to_integer(card)
    editor = socket.assigns.editor
    owner = Enum.find_value(editor.places, fn {place, cards} -> if card in cards, do: place end)
    limit = if editor.target == :kitty, do: 3, else: 5

    places =
      cond do
        owner == editor.target ->
          Map.update!(editor.places, owner, &List.delete(&1, card))

        length(Map.get(editor.places, editor.target, [])) >= limit ->
          editor.places

        owner != nil ->
          editor.places
          |> Map.update!(owner, &List.delete(&1, card))
          |> Map.update(editor.target, [card], &(&1 ++ [card]))

        true ->
          Map.update(editor.places, editor.target, [card], &(&1 ++ [card]))
      end

    {:noreply, assign(socket, editor: %{editor | places: places})}
  end

  def handle_event("editor_clear", _params, socket) do
    editor = socket.assigns.editor

    {:noreply,
     assign(socket, editor: %{editor | places: Map.put(editor.places, editor.target, [])})}
  end

  def handle_event("editor_clear_all", _params, socket) do
    editor = socket.assigns.editor
    {:noreply, assign(socket, editor: %{editor | places: %{}})}
  end

  def handle_event("editor_form", %{"editor" => params}, socket) do
    editor = socket.assigns.editor
    n = editor.variant.n

    dealer =
      case Integer.parse(params["dealer"] || "") do
        {d, ""} when d in 0..(n - 1)//1 -> d
        _ -> editor.dealer
      end

    scores =
      editor.scores
      |> Enum.with_index()
      |> Enum.map(fn {old, i} ->
        case Integer.parse(params["score_#{i}"] || "") do
          {s, ""} when s in -995..995 -> s
          _ -> old
        end
      end)

    {:noreply, assign(socket, editor: %{editor | dealer: dealer, scores: scores})}
  end

  def handle_event("editor_apply", _params, socket) do
    editor = socket.assigns.editor
    deck = deck_from(editor)

    setup = %Setup{
      variant: editor.variant,
      seed: new_seed(),
      dealer: editor.dealer,
      scores: editor.scores,
      decks: %{1 => deck}
    }

    {:noreply,
     socket
     |> assign(
       setup: setup,
       settings: socket.assigns.settings || %Settings{},
       actions: [],
       mainline: nil,
       finished: false
     )
     |> assign(judgments: %{}, judged_upto: 0, dialog: nil, editor: nil)
     |> goto(0)
     |> push_game()}
  end

  def handle_event("setup_deal", %{"game" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    {:ok, variant} = Variant.get(form["variant"])
    settings = settings_from(form)

    editor = %{
      variant: variant,
      places: %{},
      target: 0,
      dealer: variant.n - 1,
      scores: List.duplicate(0, Variant.sides(variant))
    }

    {:noreply, assign(socket, form: form, settings: settings, dialog: :editor, editor: editor)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Helpers

  # The seat whose hand is shown, when it is that seat's move and the board
  # plays for it.
  defp hand_seat_if_acting(a) do
    seat = hand_seat(a)
    if (a.state && seat in Engine.to_act(a.state)) and human?(a, seat), do: seat
  end

  defp start_game(socket, form, decks) do
    {:ok, variant} = Variant.get(form["variant"] || "team4")
    settings = settings_from(form)

    dealer =
      case form["dealer"] do
        "me" -> 0
        "left" -> 1
        _ -> :rand.uniform(variant.n) - 1
      end

    setup = %Setup{variant: variant, seed: new_seed(), dealer: dealer, decks: decks}

    socket
    |> assign(
      form: form,
      setup: setup,
      settings: settings,
      actions: [],
      mainline: nil,
      finished: false,
      judgments: %{},
      judged_upto: 0
    )
    |> assign(control_all: false, reveal: false, dialog: nil)
    |> goto(0)
    |> push_game()
  end

  defp settings_from(form) do
    strength = if form["opponents"] == "strong", do: :strong, else: :site

    %Settings{
      mode: if(form["mode"] == "play", do: :play, else: :analysis),
      opponents: strength,
      partner: strength
    }
  end

  defp new_seed, do: :rand.uniform(0xFFFFFFF)

  # The editor opens on the current hand as dealt.
  defp editor_from(%{state: state, setup: setup}) do
    n = setup.variant.n
    kitty = Enum.slice(state.deck, 5 * n, 3)

    %{
      variant: setup.variant,
      places: Map.put(Map.new(0..(n - 1), &{&1, Enum.take(state.dealt[&1], 5)}), :kitty, kitty),
      target: 0,
      dealer: state.dealer,
      scores: state_scores_before(state)
    }
  end

  defp state_scores_before(%{phase: phase, result: %{change: change}} = state)
       when phase in [:hand_over, :game_over],
       do: Enum.zip_with(state.scores, change, &(&1 - &2))

  defp state_scores_before(state), do: state.scores

  # Chosen cards go where they were put; everything else is shuffled in.
  defp deck_from(editor) do
    n = editor.variant.n
    chosen = editor.places |> Map.values() |> List.flatten()
    pool = Enum.shuffle(Enum.to_list(0..51) -- chosen)

    {seats, pool} =
      Enum.map_reduce(0..(n - 1), pool, fn p, pool ->
        mine = Map.get(editor.places, p, [])
        {fill, pool} = Enum.split(pool, 5 - length(mine))
        {mine ++ fill, pool}
      end)

    kitty = Map.get(editor.places, :kitty, [])
    {fill, pool} = Enum.split(pool, 3 - length(kitty))
    List.flatten(seats) ++ kitty ++ fill ++ pool
  end

  ## Render

  @impl true
  def render(%{state: nil} = assigns) do
    ~H"""
    <.setup_screen form={@form} dialog={@dialog} editor={@editor} />
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:hints, hints?(assigns))
      |> assign(:focus, focus_seat(assigns))
      |> assign(:hand_seat, hand_seat(assigns))
      |> assign(:live, live?(assigns))
      |> assign(:show_options, show_options?(assigns))

    ~H"""
    <.board {assigns} />
    """
  end
end
