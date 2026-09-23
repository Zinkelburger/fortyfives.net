defmodule Website45sV3Web.AdminHTML do
  use Website45sV3Web, :html

  embed_templates "admin_html/*"

  def human_bytes(nil), do: "0 B"
  def human_bytes(n) when n < 1024, do: "#{n} B"
  def human_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def human_bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / (1024 * 1024), 1)} MB"
  def human_bytes(n), do: "#{Float.round(n / (1024 * 1024 * 1024), 2)} GB"

  def duration(nil), do: "-"

  def duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{String.pad_leading(Integer.to_string(seconds), 2, "0")}s"
  end

  def when_at(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def when_at(_), do: "-"

  def pct(nil), do: "-"
  def pct(n), do: "#{n}%"

  def seconds(nil), do: "-"
  def seconds(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  def seconds(ms), do: duration(ms)
end
