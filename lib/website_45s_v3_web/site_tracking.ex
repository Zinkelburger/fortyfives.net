defmodule Website45sV3Web.SiteTracking do
  @moduledoc """
  Records `Website45sV3.Analytics.SiteEvent`s from LiveViews: a page view
  each time a connected view lands on a new route, and whatever the view
  reports through `track/3` (joining the queue, adding a bot, ...).

  Only connected sockets are tracked, and known crawlers are skipped, so the
  numbers count people whose browser ran the page. Paths are stored as the
  route pattern (`/game/:id`), never with ids or tokens in them.

  Mount it with `on_mount: [{Website45sV3Web.SiteTracking, :default}]`
  after the hook that assigns `:user_id`.
  """
  require Logger

  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Repo

  @crawler ~r/bot|crawl|spider|slurp|headless|lighthouse|preview|facebookexternalhit/i
  @mobile ~r/Mobi|Android|iPhone|iPad/

  def on_mount(:default, _params, session, socket) do
    socket = Phoenix.Component.assign(socket, :site_tracking, context(socket, session))

    if socket.assigns.site_tracking && socket.router do
      {:cont, Phoenix.LiveView.attach_hook(socket, :site_tracking, :handle_params, &page_view/3)}
    else
      {:cont, socket}
    end
  end

  @doc """
  Records `name` for this socket's visitor. A no-op for sockets that are not
  tracked (disconnected renders, crawlers, tests that build sockets by hand).
  """
  def track(socket, name, attrs \\ %{})

  def track(%{assigns: %{site_tracking: %{} = context}}, name, attrs) do
    context
    |> Map.drop([:last_route])
    |> Map.merge(Map.new(attrs))
    |> Map.put(:name, name)
    |> insert()
  end

  def track(_socket, _name, _attrs), do: :ok

  defp context(socket, session) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent) || ""

    with true <- Phoenix.LiveView.connected?(socket),
         visitor_id when is_binary(visitor_id) <- session["visitor_id"],
         false <- Regex.match?(@crawler, user_agent) do
      params = Phoenix.LiveView.get_connect_params(socket) || %{}

      %{
        visitor_id: visitor_id,
        player_id: session["user_id"],
        device: if(Regex.match?(@mobile, user_agent), do: "mobile", else: "desktop"),
        viewport_w: positive_int(params["_vw"]),
        viewport_h: positive_int(params["_vh"]),
        referrer: referrer_host(params["_ref"]),
        last_route: nil
      }
    else
      _ -> nil
    end
  end

  defp page_view(_params, uri, socket) do
    path = URI.parse(uri).path
    route = route_pattern(socket.router, path)
    context = socket.assigns.site_tracking

    # handle_params also runs for patches within a page (tabs, modals);
    # only a move to a different route counts as a new page.
    if route && route != context.last_route do
      track(socket, "page_view", %{path: route})

      {:cont, Phoenix.Component.assign(socket, :site_tracking, %{context | last_route: route})}
    else
      {:cont, socket}
    end
  end

  defp route_pattern(router, path) do
    case Phoenix.Router.route_info(router, "GET", path, nil) do
      %{route: route} -> route
      _ -> nil
    end
  end

  # Our own pages are not a referrer; neither is an empty or garbled value.
  defp referrer_host(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host = host |> String.downcase() |> String.replace_prefix("www.", "")
        if host in ["fortyfives.net", "localhost"], do: nil, else: String.slice(host, 0, 100)

      _ ->
        nil
    end
  end

  defp referrer_host(_url), do: nil

  defp positive_int(n) when is_integer(n) and n > 0 and n < 20_000, do: n
  defp positive_int(_n), do: nil

  # Analytics must never take a page down: a failed write is logged and
  # dropped.
  defp insert(attrs) do
    case %SiteEvent{} |> SiteEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _event} -> :ok
      {:error, changeset} -> Logger.debug("site event dropped: #{inspect(changeset.errors)}")
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      Logger.warning("site event not recorded: #{Exception.message(error)}")
  end
end
