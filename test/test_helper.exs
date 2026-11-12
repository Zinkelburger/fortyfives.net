# The analysis board's trained weights are not in git (they come from the
# private Frank-45s-Opus repo); tests that need a missing file are skipped.
weights = ~w(team4 ct2 ct3 ct4 ct5 ct6)

missing =
  Enum.reject(
    weights,
    &File.regular?(Path.join(Website45sV3.Analysis.Net.weights_dir(), &1 <> ".bin"))
  )

exclude = Enum.map(missing, &{:weights, &1}) ++ if(missing == [], do: [], else: [weights: "all"])

ExUnit.start(capture_log: true, exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Website45sV3.Repo, :manual)
