defmodule Website45sV3Web.Layouts do
  @moduledoc """
  The root, game-root and app layouts, plus the helpers their `<head>` needs:
  the page description, the canonical URL and the robots directive.

  `canonical_path` is assigned per request by `UserAuth.assign_canonical_path/2`
  (and by the LiveView `handle_params` hook) and is the request path without a
  query string, so `/play?tab=private` already canonicalises to `/play`.
  """
  use Website45sV3Web, :html

  @site_url "https://fortyfives.net"

  @default_description "Play the 45s card game online for free. Forty Fives (45s) is a " <>
                         "classic trick-taking card game. Create a table, invite friends, " <>
                         "and play in your browser. No download needed."

  embed_templates "layouts/*"

  @doc "The page's meta description, falling back to the site-wide one."
  def meta_description(assigns), do: assigns[:meta_description] || @default_description

  @doc """
  The absolute canonical URL for the current request. Private lobby links
  (`/play/private/<uuid>`) are per-game and canonicalise to `/play`.
  """
  def canonical_url(assigns), do: @site_url <> canonical_path(assigns[:canonical_path])

  defp canonical_path(nil), do: "/"
  defp canonical_path("/play/private/" <> _id), do: "/play"
  defp canonical_path(path), do: path

  @doc """
  Whether search engines should skip the page: the live queue and private
  lobbies are dynamic, per-session pages with nothing durable to index.
  """
  def noindex?(assigns), do: noindex_path?(assigns[:canonical_path])

  defp noindex_path?("/play"), do: true
  defp noindex_path?("/play/private/" <> _id), do: true
  defp noindex_path?(_path), do: false
end
