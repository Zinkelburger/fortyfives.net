defmodule Website45sV3.FailingMailAdapter do
  @moduledoc """
  A Bamboo adapter whose every delivery fails, for exercising the paths that
  run when the mail provider is down.

  Swap it in with `Website45sV3.FailingMailAdapter.enable/0` (restored on
  exit). `Bamboo.Mailer` reads its adapter from application config on every
  `deliver_now/1`, so the switch takes effect immediately.
  """

  @behaviour Bamboo.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, %Bamboo.ApiError{message: "SES is unavailable"}}

  @impl true
  def handle_config(config), do: config

  @impl true
  def supports_attachments?, do: false

  @doc """
  Makes the application mailer fail until the calling test exits.
  Must be used from a non-async test, since mailer config is global.
  """
  def enable do
    previous = Application.get_env(:website_45s_v3, Website45sV3.Mailer)
    Application.put_env(:website_45s_v3, Website45sV3.Mailer, adapter: __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:website_45s_v3, Website45sV3.Mailer, previous)
    end)

    :ok
  end
end
