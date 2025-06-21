defmodule Website45sV3Web.UserLoginLive do
  use Website45sV3Web, :live_view

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm mt-3">
      <.header class="text-center">
        Sign in
          <:subtitle>
            Don't have an account?
            <.link
              navigate={~p"/users/register"}
              class="font-semibold link"
            >
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
              phx-change="update_form"
              required
              phx-debounce="400"
              background_color="071f31"
            />
          </div>
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            show_password={@show_password}
            phx-change="update_form"
            required
            phx-debounce="400"
          />
            <:actions>
              <.input field={@form[:remember_me]} type="checkbox" label="Keep me logged in" />
              <li style="margin-top: 0.25rem; margin-bottom: 0; list-style-type: none;">
                <.link href={~p"/users/reset_password"} class="text-sm font-semibold">
                  Forgot your password?
                </.link>
              </li>
            </:actions>
            <:actions>
            <.button phx-disable-with="Signing in..." class="green-button w-full" style="margin-bottom: 0; margin-top: 0;">
              Sign in <span aria-hidden="true">→</span>
            </.button>
          </:actions>
          <:actions>
              <.link
                href={~p"/auth/google"}
                class="google-button w-full"
              >
                <img src="/images/google_logo.svg" alt="Google logo" />
                <span>Sign in with Google</span>
              </.link>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    email = live_flash(socket.assigns.flash, :email) || ""

    form_data = %{
      "username_or_email" => email,
      "password" => ""
    }

    socket =
      socket
      |> assign(:form_data, form_data)
      |> assign_form(form_data)
      |> assign(:show_password, false)

    {:ok, socket}
  end

  def handle_event("toggle_visibility", _value, socket) do
    socket = socket |> assign(show_password: not socket.assigns.show_password)
    {:noreply, assign_form(socket, socket.assigns.form_data)}
  end

  def handle_event("update_form", %{"user" => new_form_data}, socket) do
    updated_form_data = Map.merge(socket.assigns.form_data, new_form_data)
    socket = socket |> assign(form_data: updated_form_data)
    {:noreply, assign_form(socket, updated_form_data)}
  end

  defp assign_form(socket, form_data) do
    form = to_form(form_data, as: "user")
    assign(socket, form: form)
  end
end
