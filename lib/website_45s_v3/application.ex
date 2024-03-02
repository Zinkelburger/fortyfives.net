defmodule Website45sV3.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Registry
      {Registry, keys: :unique, name: Website45sV3.Registry},
      # Start the Telemetry supervisor
      Website45sV3Web.Telemetry,
      # Start the Ecto repository
      Website45sV3.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Website45sV3.PubSub},
      Website45sV3Web.Presence,
      # Start Finch
      {Finch, name: Website45sV3.Finch},
      # Start the Endpoint (http/https)
      Website45sV3Web.Endpoint,
      Website45sV3.Game.QueueStarter
      # Start a worker by calling: Website45sV3.Worker.start_link(arg)
      # {Website45sV3.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Website45sV3.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Website45sV3Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
