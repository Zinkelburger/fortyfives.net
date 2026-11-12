defmodule Website45sV3.Analysis.Advisor do
  @moduledoc """
  The bots and the analysis behind the board.

  `options/2` values every legal choice for a seat with the trained network
  for the variant, from what that seat may know: expected points for the
  hand, as the seat's result against the table (in partners, its team's
  score change minus the opponents'; in cutthroat, its own change minus the
  average of the others'). `move/3` picks a bot move: `:strong` is the
  network's best choice, `:site` the site's own bot.
  """
  alias Website45sV3.Analysis.CtPolicy
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Heuristic
  alias Website45sV3.Analysis.Net
  alias Website45sV3.Analysis.TeamPolicy

  # The networks are trained on points / 30.
  @scale 30

  @typedoc "An action with its value in points."
  @type option :: %{action: Engine.action(), points: float()}

  @doc "Whether a trained network exists for the variant."
  def available?(variant), do: policy(variant) != nil

  defp policy(variant) do
    case Net.policy(variant.id) do
      %{} = policy -> policy
      _ -> nil
    end
  end

  @doc """
  Every legal choice for `seat`, best first, or `[]` when the seat has no
  decision or no network is available.
  """
  def options(%Engine{} = state, seat) do
    with policy when policy != nil <- policy(state.variant),
         decision when decision != nil <- Engine.decision(state, seat) do
      state
      |> values(policy, seat, decision)
      |> Enum.map(fn {action, q} -> %{action: action, points: q * @scale} end)
      |> Enum.sort_by(& &1.points, :desc)
    else
      _ -> []
    end
  end

  defp values(state, policy, seat, {:bid, legal}) do
    view = Engine.bid_view(state, seat)
    legal = MapSet.new(legal)

    policy
    |> bid_values(state, view)
    |> Enum.filter(fn {bid, _} -> MapSet.member?(legal, bid) end)
    |> Enum.map(fn {bid, q} -> {{:bid, seat, bid}, q} end)
  end

  defp values(state, policy, seat, {:keep, _cards, _min}) do
    view = Engine.keep_view(state, seat)

    policy
    |> keep_values(state, view)
    |> Enum.map(fn {kept, q} -> {{:keep, seat, kept}, q} end)
  end

  defp values(state, policy, seat, {:play, legal}) do
    view = Engine.play_view(state, seat)

    case legal do
      [only] -> [{{:play, seat, only}, card_values(policy, state, view) |> value_of(only)}]
      _ -> Enum.map(card_values(policy, state, view), fn {c, q} -> {{:play, seat, c}, q} end)
    end
  end

  defp value_of(values, card) do
    Enum.find_value(values, 0.0, fn {c, q} -> if c == card, do: q end)
  end

  defp bid_values(%{kind: :team} = p, _state, view), do: TeamPolicy.bid_values(p, team_view(view))
  defp bid_values(p, _state, view), do: CtPolicy.bid_values(p, view)

  defp keep_values(%{kind: :team} = p, _state, view),
    do: TeamPolicy.keep_values(p, team_view(view))

  defp keep_values(p, _state, view), do: CtPolicy.keep_values(p, view)

  defp card_values(%{kind: :team} = p, _state, view),
    do: TeamPolicy.card_values(p, team_view(view))

  defp card_values(p, _state, view), do: CtPolicy.card_values(p, view)

  # The partnership network reads team totals.
  defp team_view(view) do
    view =
      if Map.has_key?(view, :tricks) do
        t = view.tricks
        %{view | tricks: {elem(t, 0) + elem(t, 2), elem(t, 1) + elem(t, 3)}}
      else
        view
      end

    %{view | score: {elem(view.score, 0), elem(view.score, 1)}}
  end

  @doc "A bot's move for `seat`. Falls back to the site bot when no network exists."
  def move(%Engine{} = state, seat, strength) do
    case {strength, options(state, seat)} do
      {:strong, [%{action: action} | _]} -> action
      _ -> heuristic_move(state, seat)
    end
  end

  defp heuristic_move(state, seat) do
    case Engine.decision(state, seat) do
      {:bid, _} -> {:bid, seat, Heuristic.bid(Engine.bid_view(state, seat))}
      {:keep, _, _} -> {:keep, seat, Heuristic.keep(Engine.keep_view(state, seat))}
      {:play, _} -> {:play, seat, Heuristic.play(Engine.play_view(state, seat))}
      nil -> nil
    end
  end

  ## Judging a move

  @doc """
  How much a move gave away against the best choice, in points, and its
  class: `:best`, `:good`, `:inaccuracy`, `:mistake` or `:blunder`.
  """
  def judge([], _action), do: nil

  def judge([best | _] = options, action) do
    chosen = Enum.find(options, &same?(&1.action, action))

    if chosen do
      loss = max(best.points - chosen.points, 0.0)
      %{best: best, chosen: chosen, loss: loss, class: class(loss, chosen == best)}
    end
  end

  defp same?({:keep, s, a}, {:keep, s, b}), do: Enum.sort(a) == Enum.sort(b)
  defp same?(a, b), do: a == b

  # A trick is worth 5 and a set bid usually 20 or more, so these are points
  # a player at the table would notice.
  def class(_loss, true), do: :best
  def class(loss, _) when loss < 1.5, do: :good
  def class(loss, _) when loss < 4, do: :inaccuracy
  def class(loss, _) when loss < 8, do: :mistake
  def class(_loss, _), do: :blunder

  @doc "Accuracy of a list of judged moves, 0–100: each move scores 100·e^(−loss/8)."
  def accuracy([]), do: nil

  def accuracy(judged) do
    total = Enum.reduce(judged, 0.0, fn j, acc -> acc + 100 * :math.exp(-j.loss / 8) end)
    round(total / length(judged))
  end
end
