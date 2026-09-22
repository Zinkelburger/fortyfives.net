defmodule Website45sV3Web.UserLoginLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers, only: [password_field: 1]

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm mt-3">
      <.header class="text-center">
        Sign in
        <:subtitle>
          Don't have an account?
          <.link navigate={~p"/users/register"} class="font-semibold link">
            <span style="text-decoration: underline;">Sign up</span>
          </.link>
        </:subtitle>
      </.header>

      <div
        class="mx-auto max-w-sm"
        style="background-color: #071f31; padding-right: 10px; padding-left: 10px; border-radius: 10px; margin-top:0px; margin-bottom: 0px; border: 2px #d2e8f9 solid;"
      >
        <.simple_form for={@form} id="login_form" action={~p"/users/log_in"}>
          <div style="padding-top:5px;">
            <.input
              field={@form[:username_or_email]}
              type="text"
              label="Username or email"
              required
              background_color="071f31"
            />
          </div>
          <.password_field
            field={@form[:password]}
            label="Password"
            autocomplete="current-password"
            required
          />
          <.turnstile id="login-turnstile" />
          <:actions>
            <.input field={@form[:remember_me]} type="checkbox" label="Keep me logged in" />
            <li style="margin-top: 0.25rem; margin-bottom: 0; list-style-type: none;">
              <.link
                href={~p"/users/reset_password"}
                class="text-sm font-semibold"
                style="text-decoration: underline;"
              >
                Forgot your password?
              </.link>
            </li>
          </:actions>
          <:actions>
            <.button
              phx-disable-with="Signing in..."
              class="green-button w-full"
              style="margin-bottom: 0; margin-top: 0;"
            >
              Sign in <span aria-hidden="true">→</span>
            </.button>
          </:actions>
          <:actions>
            <.link href={~p"/auth/google"} class="google-button w-full">
              <img src="/images/google_logo.svg" alt="Google logo" />
              <span>Sign in with Google</span>
            </.link>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  # The form posts straight to the session controller; nothing is tracked
  # live, so the password never reaches this process.
  def mount(_params, _session, socket) do
    username_or_email = Phoenix.Flash.get(socket.assigns.flash, :username_or_email) || ""
    form = to_form(%{"username_or_email" => username_or_email}, as: "user")

    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
  end
end
