defmodule Website45sV3Web.UserRegistrationLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers,
    only: [client_ip: 1, password_field: 1, refuse_submit: 3]

  require Logger

  alias Website45sV3.Accounts
  alias Website45sV3.Accounts.User
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3.Turnstile

  def render(assigns) do
    ~H"""
    <.header class="text-center mx-auto max-w-sm mt-3">
      Register
      <:subtitle>
        Or
        <.link
          navigate={~p"/users/log_in"}
          class="font-semibold link"
          style="font-weight: bold;"
        >
          <span style="text-decoration: underline;">Sign in</span>
        </.link>
        to your account
      </:subtitle>
    </.header>
    <div
      class="mx-auto max-w-sm"
      style="background-color: #071f31; padding-right: 10px; padding-left: 10px; border-radius: 10px; margin-top:0px; margin-bottom: 0px; border: 2px #d2e8f9 solid;"
    >
      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/users/log_in?_action=registered"}
        method="post"
      >
        <input type="hidden" name="post_auth_token" value={@post_auth_token} />
        <.error :if={@check_errors}>
          Oops, something went wrong! Please check the errors below.
        </.error>

        <div style="padding-top:5px;">
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            required
            phx-debounce="400"
            background_color="071f31"
          />
        </div>
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          required
          phx-debounce="400"
          background_color="071f31"
        />
        <.password_field
          field={@form[:password]}
          label="Password"
          autocomplete="new-password"
          required
          phx-debounce="400"
        />

        <.turnstile id="registration-turnstile" />

        <:actions>
          <.button
            phx-disable-with="Creating account..."
            class="w-full green-button"
            style="margin-bottom: 0; margin-top: 0;"
          >
            Create an account
          </.button>
        </:actions>
        <:actions>
          <.link
            href={~p"/auth/google"}
            class="google-button w-full"
          >
            <img src="/images/google_logo.svg" alt="Google logo" />
            <span>Sign up with Google</span>
          </.link>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    socket =
      socket
      |> assign(trigger_submit: false, check_errors: false, post_auth_token: nil)
      |> assign(:client_ip, client_ip(socket))
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params} = params, socket) do
    client_ip = socket.assigns.client_ip

    # Turnstile gates the attempt, then a per-network budget caps how many
    # accounts (and therefore confirmation emails) one source can create. The
    # budget is only *checked* here and charged after the account exists, so a
    # rejected changeset costs the visitor nothing.
    with :ok <- Turnstile.verify(params["cf-turnstile-response"], client_ip),
         :ok <- registration_allowed(client_ip),
         {:ok, user} <- Accounts.register_user(user_params) do
      RateLimiter.record_registration(client_ip)

      # The account exists either way; a mail failure must not crash the
      # sign-in that follows. The session controller turns the marker into a
      # flash telling the user to request a new confirmation email.
      payload =
        case deliver_confirmation(user) do
          :ok -> {:registered, user.id}
          :error -> {:registered, user.id, :confirmation_email_failed}
        end

      changeset = Accounts.change_user_registration(user)
      post_auth_token = Phoenix.Token.sign(socket, "post-auth", payload)

      {:noreply,
       socket
       |> assign(trigger_submit: true, post_auth_token: post_auth_token)
       |> assign_form(changeset)}
    else
      {:error, reason} when reason in [:turnstile_failed, :rate_limited] ->
        {:noreply,
         refuse_submit(
           socket,
           reason,
           "Too many accounts created from your network. Please try later."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        # The Turnstile token was consumed by the failed attempt; reset the
        # widget so the retry submits a fresh one.
        {:noreply,
         socket
         |> assign(check_errors: true)
         |> assign_form(changeset)
         |> push_event("turnstile:reset", %{})}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp deliver_confirmation(user) do
    case Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}")) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not send confirmation email to user #{user.id}: #{inspect(reason)}")
        :error
    end
  end

  defp registration_allowed(client_ip) do
    if RateLimiter.registration_exhausted?(client_ip),
      do: {:error, :rate_limited},
      else: :ok
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end
end
