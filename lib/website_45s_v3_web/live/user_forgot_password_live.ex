defmodule Website45sV3Web.UserForgotPasswordLive do
  use Website45sV3Web, :live_view

  alias Website45sV3.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center mt-3">
        Forgot your password?
        <:subtitle>We'll send a password reset link to your inbox</:subtitle>
      </.header>

      <.simple_form for={@form} id="reset_password_form" phx-submit="send_email" background_color="041624">
        <.input field={@form[:email]} type="email" placeholder="Email" required background_color="041624"/>
        <:actions>
          <.button phx-disable-with="Sending..." class="w-full green-button mt-1">
            Send reset instructions
          </.button>
        </:actions>
      </.simple_form>
      <p style="color:#d2e8f9;" class="text-center text-sm mt-1 li">
        <.link href={~p"/users/register"}
          class="font-semibold link"
          style="font-weight: bold; text-decoration: underline;">
          Register</.link>
        | <.link href={~p"/users/log_in"}
        class="font-semibold link"
          style="font-weight: bold; text-decoration: underline;">Log in</.link>
      </p>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset_password/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
