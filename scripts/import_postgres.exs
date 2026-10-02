# Run against a restored PostgreSQL dump, with a NEW destination file:
# SOURCE_DATABASE_URL=ecto://... DATABASE_PATH=/absolute/new.db \
#   mix run --no-start scripts/import_postgres.exs
# No web app, sweepers, or mailers start during conversion.
defmodule MigrationSource do
  use Ecto.Repo, otp_app: :website_45s_v3, adapter: Ecto.Adapters.Postgres
end

import Ecto.Query
alias Website45sV3.Repo

path = System.fetch_env!("DATABASE_PATH")
if File.exists?(path), do: raise("Destination already exists; refusing to overwrite")
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sqlite3)
Logger.configure(level: :warning)
{:ok, _} = MigrationSource.start_link(url: System.fetch_env!("SOURCE_DATABASE_URL"), pool_size: 1)
{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

schemas = [
  Website45sV3.Accounts.User,
  Website45sV3.Accounts.UserToken,
  Website45sV3.Game.GameLog,
  Website45sV3.Analytics.Replay,
  Website45sV3.Analytics.ReplayChunk,
  Website45sV3.Analytics.ReplayClick,
  Website45sV3.Analytics.SiteEvent
]

{:ok, :ok} =
  MigrationSource.transaction(
    fn ->
      Ecto.Adapters.SQL.query!(
        MigrationSource,
        "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"
      )

      {:ok, :ok} =
        Repo.transaction(
          fn ->
            for schema <- schemas do
              table = schema.__schema__(:source)
              fields = schema.__schema__(:fields)

              %{rows: columns} =
                Ecto.Adapters.SQL.query!(
                  MigrationSource,
                  "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
                  [table]
                )

              unless MapSet.new(List.flatten(columns)) ==
                       MapSet.new(Enum.map(fields, &Atom.to_string/1)),
                     do: raise("Unmapped source columns in #{table}")

              rows = MigrationSource.all(from(r in schema, order_by: r.id), timeout: :infinity)
              entries = Enum.map(rows, &Map.take(&1, fields))
              for batch <- Enum.chunk_every(entries, 100), do: Repo.insert_all(schema, batch)

              copied =
                Repo.all(from(r in schema, order_by: r.id)) |> Enum.map(&Map.take(&1, fields))

              unless copied == entries,
                do: raise("Data mismatch in #{schema.__schema__(:source)}")

              # Preserve sequence high-water marks even if the highest rows were pruned.
              %{rows: [[last_id]]} =
                Ecto.Adapters.SQL.query!(
                  MigrationSource,
                  "SELECT last_value FROM #{table}_id_seq"
                )

              Ecto.Adapters.SQL.query!(Repo, "DELETE FROM sqlite_sequence WHERE name = ?", [table])

              Ecto.Adapters.SQL.query!(
                Repo,
                "INSERT INTO sqlite_sequence(name, seq) VALUES (?, ?)",
                [table, last_id]
              )

              IO.puts(
                "VERIFIED #{schema.__schema__(:source)}: #{length(entries)} rows, all fields equal"
              )
            end

            :ok
          end,
          timeout: :infinity
        )

      :ok
    end,
    timeout: :infinity
  )

%{rows: [["ok"]]} = Ecto.Adapters.SQL.query!(Repo, "PRAGMA integrity_check")
%{rows: []} = Ecto.Adapters.SQL.query!(Repo, "PRAGMA foreign_key_check")
Ecto.Adapters.SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)")
IO.puts("VERIFIED integrity, foreign keys, and WAL checkpoint")
