defmodule Website45sV3.Analysis.Net do
  @moduledoc """
  Weights and evaluation for the trained 45s value nets (Frank-45s-Opus `core/nn.hpp`:
  sparse binary input -> h1 -> h2 -> 1, ReLU).

  A policy is `%{kind: :team | :ct, players: n, use_score: bool, nets: %{bid:, pass:, keep:, play:}}`.
  `policy/1` loads `<weights_dir>/<variant>.bin` on first use and keeps it in
  `:persistent_term`; it returns nil when the variant has no weights, so callers
  can fall back to `Website45sV3.Analysis.Heuristic`.
  """

  @variants ~w(team4 ct2 ct3 ct4 ct5 ct6)
  @ct_magic 0x43543435

  @type net :: %{
          w1: tuple(),
          b1: [float()],
          w2: [binary()],
          b2: [float()],
          w3: [float()],
          b3: float()
        }
  @type policy :: %{
          kind: :team | :ct,
          players: pos_integer(),
          use_score: boolean(),
          nets: %{atom() => net()}
        }

  @doc ~s[The weights for a variant ("team4", "ct2".."ct6"), loaded once; nil if absent.]
  @spec policy(String.t()) :: policy() | nil
  def policy(variant) when variant in @variants do
    key = {__MODULE__, variant}

    case :persistent_term.get(key, :unloaded) do
      :unloaded -> :global.trans({key, self()}, fn -> load_once(key, variant) end, [node()])
      p -> p
    end
  end

  def policy(_), do: nil

  # Under the lock: another process may have loaded it while we waited.
  defp load_once(key, variant) do
    case :persistent_term.get(key, :unloaded) do
      :unloaded ->
        p = load_variant(variant)
        :persistent_term.put(key, p)
        p

      p ->
        p
    end
  end

  defp load_variant(variant) do
    path = Path.join(weights_dir(), variant <> ".bin")

    cond do
      not File.regular?(path) ->
        nil

      variant == "team4" ->
        load_team!(path)

      true ->
        p = load_ct!(path)
        n = String.to_integer(String.trim_leading(variant, "ct"))
        if p.players != n, do: raise("#{path} is for #{p.players} players")
        p
    end
  end

  @doc """
  Where the weight files live: `ANALYSIS_WEIGHTS_DIR` (config `:analysis_weights_dir`),
  else `priv/analysis`. The files come from the private Frank-45s-Opus repo and are
  not in git.
  """
  def weights_dir do
    Application.get_env(:website_45s_v3, :analysis_weights_dir) ||
      Application.app_dir(:website_45s_v3, ["priv", "analysis"])
  end

  @doc "A partnership policy file (`Policy::save`: int use_score, then 4 nets)."
  def load_team!(path) do
    <<us::little-signed-32, rest::binary>> = File.read!(path)
    %{kind: :team, players: 4, use_score: us != 0, nets: read_nets(rest)}
  end

  @doc "A cutthroat policy file (`CtPolicy::save`: magic, int players, 4 nets)."
  def load_ct!(path) do
    case File.read!(path) do
      <<@ct_magic::little-32, players::little-32, rest::binary>> ->
        %{kind: :ct, players: players, use_score: false, nets: read_nets(rest)}

      _ ->
        raise ArgumentError, "not a cutthroat policy: #{path}"
    end
  end

  defp read_nets(bin) do
    {nets, <<>>} =
      Enum.map_reduce([:bid, :pass, :keep, :play], bin, fn name, bin ->
        {net, bin} = read_net(bin)
        {{name, net}, bin}
      end)

    Map.new(nets)
  end

  # W1 and W2 rows stay float32 binaries (slices of the file): an eighth of the memory of
  # float lists, and about as fast to add up.
  defp read_net(<<i::little-32, h1::little-32, h2::little-32, bin::binary>>) do
    {w1, bin} = rows(bin, i, h1)
    {b1, bin} = floats(bin, h1)
    {w2, bin} = rows(bin, h1, h2)
    {b2, bin} = floats(bin, h2)
    {w3, bin} = floats(bin, h2)
    {[b3], bin} = floats(bin, 1)
    {%{w1: List.to_tuple(w1), b1: b1, w2: w2, b2: b2, w3: w3, b3: b3}, bin}
  end

  defp rows(bin, n, width) do
    size = width * 4
    total = n * size
    <<head::binary-size(^total), rest::binary>> = bin
    {for(<<row::binary-size(^size) <- head>>, do: row), rest}
  end

  defp floats(bin, n) do
    size = n * 4
    <<head::binary-size(^size), rest::binary>> = bin
    {for(<<x::little-float-32 <- head>>, do: x), rest}
  end

  ## Evaluation

  @doc "Layer-1 pre-activations for a list of active inputs."
  def base(net, active), do: add_rows(net.b1, net, active)

  @doc "Adds the W1 rows of `active` inputs to pre-activations `acc`."
  def add_rows(acc, net, active) do
    Enum.reduce(active, acc, fn i, acc -> vadd(acc, elem(net.w1, i)) end)
  end

  @doc "Output from layer-1 pre-activations."
  def tail(net, a1) do
    a1 |> layer2(net.w2, net.b2) |> out(net.w3, net.b3)
  end

  @doc "Output for a list of active inputs."
  def eval(net, active), do: tail(net, base(net, active))

  defp vadd([a | as], <<w::little-float-32, ws::binary>>), do: [a + w | vadd(as, ws)]
  defp vadd([], <<>>), do: []

  defp layer2([x | xs], [_ | rows], acc) when x <= 0, do: layer2(xs, rows, acc)
  defp layer2([x | xs], [row | rows], acc), do: layer2(xs, rows, axpy(acc, row, x))
  defp layer2([], [], acc), do: acc

  defp axpy([a | as], <<w::little-float-32, ws::binary>>, x), do: [a + x * w | axpy(as, ws, x)]
  defp axpy([], <<>>, _x), do: []

  defp out([x | xs], [w | ws], o) when x > 0, do: out(xs, ws, o + x * w)
  defp out([_ | xs], [_ | ws], o), do: out(xs, ws, o)
  defp out([], [], o), do: o
end
