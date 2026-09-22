defmodule Website45sV3Web.AuthLiveHelpers do
  @moduledoc """
  Pieces shared by the account LiveViews: resolving the client IP from the
  socket, the Turnstile-then-rate-limit gate in front of unauthenticated
  email sends, and a password input whose show/hide toggle is handled in the
  browser so the typed password never travels to the server on a click.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [get_connect_info: 2, push_event: 3, put_flash: 3]
  import Website45sV3Web.CoreComponents, only: [label: 1, error: 1, translate_error: 1]

  alias Phoenix.LiveView.JS
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3.Turnstile

  @doc """
  Best-effort client IP for a LiveView socket, or `nil` during static render.
  """
  def client_ip(socket) do
    Turnstile.client_ip(
      get_connect_info(socket, :x_headers),
      get_connect_info(socket, :peer_data)
    )
  end

  @doc """
  Admission check for an action that sends mail to an address the visitor
  typed (password reset, confirmation resend).

  Turnstile runs first, so an unsolved challenge cannot burn a victim's mail
  budget; the limiter then caps how much mail one network or one inbox can be
  made to receive. Both counters are charged on the submitted address whether
  or not it belongs to an account, so this leaks no membership.

  Returns `:ok`, `{:error, :turnstile_failed}` or `{:error, :rate_limited}`.
  """
  def authorize_email_send(socket, params, email) do
    client_ip = socket.assigns.client_ip

    with :ok <- Turnstile.verify(params["cf-turnstile-response"], client_ip) do
      RateLimiter.check_email_send(client_ip, email)
    end
  end

  @doc """
  Flashes the reason an admission check refused a submit and resets the
  Turnstile widget, since the failed attempt consumed its token.
  """
  def refuse_submit(socket, :turnstile_failed, _rate_limited_message) do
    socket
    |> put_flash(:error, "Please complete the verification challenge and try again.")
    |> push_event("turnstile:reset", %{})
  end

  def refuse_submit(socket, :rate_limited, rate_limited_message) do
    socket
    |> put_flash(:error, rate_limited_message)
    |> push_event("turnstile:reset", %{})
  end

  @doc """
  A password field with a show/hide toggle.

  The input (and its toggle) sit in a `phx-update="ignore"` container: the
  browser owns the typed value, so it survives re-renders without being
  echoed back from an assign, and the eye button flips the input's `type`
  with a client-side JS command instead of a round trip. Errors for the
  field render normally below it.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :background_color, :string, default: "071f31"
  attr :rest, :global, include: ~w(autocomplete phx-debounce required)

  def password_field(%{field: field} = assigns) do
    assigns =
      assign(assigns,
        id: assigns.id || field.id,
        name: assigns.name || field.name,
        errors: if(show_errors?(field), do: Enum.map(field.errors, &translate_error/1), else: [])
      )

    ~H"""
    <div style="background-color: #071f31; color: #d2e8f9;">
      <.label for={@id}>{@label}</.label>
      <div id={"#{@id}-container"} class="relative" phx-update="ignore">
        <input
          type="password"
          id={@id}
          name={@name}
          class="mt-2 block w-full rounded-m text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6 border-zinc-300 focus:border-zinc-400"
          style={"background-color: ##{@background_color}; color: #d2e8f9;"}
          {@rest}
        />
        <button
          type="button"
          phx-click={toggle_password_visibility(@id)}
          aria-label="Show or hide password"
          class="absolute top-1/2 right-0 pr-4 transform -translate-y-1/2"
        >
          <img
            id={"#{@id}-show-icon"}
            src="/images/fa-eye.svg"
            alt=""
            style="width: 20px; height: 20px;"
            class="filter-text"
          />
          <img
            id={"#{@id}-hide-icon"}
            src="/images/fa-eye-slash.svg"
            alt=""
            style="width: 20px; height: 20px;"
            class="filter-text"
            hidden
          />
        </button>
      </div>
      <div style="margin-top: -20px;">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  defp toggle_password_visibility(id) do
    JS.toggle_attribute({"type", "text", "password"}, to: "##{id}")
    |> JS.toggle_attribute({"hidden", "hidden"}, to: "##{id}-show-icon")
    |> JS.toggle_attribute({"hidden", "hidden"}, to: "##{id}-hide-icon")
  end

  # Like `Phoenix.Component.used_input?/1`, but also shows errors for fields
  # posted outside the form's nested params (e.g. `current_password` on the
  # settings page): errors are hidden only until the form has been submitted
  # or validated, and while the client reports the input as untouched.
  defp show_errors?(%{form: %{params: params}, field: name}) when is_map(params) do
    params != %{} and not Map.has_key?(params, "_unused_#{name}")
  end

  defp show_errors?(_field), do: true
end
