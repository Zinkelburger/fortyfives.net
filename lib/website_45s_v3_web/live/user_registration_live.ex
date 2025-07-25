defmodule Website45sV3Web.UserRegistrationLive do
  use Website45sV3Web, :live_view

  alias Website45sV3.Accounts
  alias Website45sV3.Accounts.User

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
        <.error :if={@check_errors}>
          Oops, something went wrong! Please check the errors below.
        </.error>

        <div style="padding-top:5px;">
          <.input field={@form[:username]} type="text" label="Username" required phx-debounce="400" background_color="071f31"/>
        </div>
        <.input field={@form[:email]} type="email" label="Email" required phx-debounce="400" background_color="071f31"/>
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          show_password={@show_password}
          required
          phx-debounce="400"
        />

        <:actions>
          <.button phx-disable-with="Creating account..." class="w-full green-button" style="margin-bottom: 0; margin-top: 0;">
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
      |> assign(trigger_submit: false, check_errors: false, show_password: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        changeset = Accounts.change_user_registration(user)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("toggle_visibility", _value, socket) do
    {:noreply, assign(socket, show_password: not socket.assigns.show_password)}
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
