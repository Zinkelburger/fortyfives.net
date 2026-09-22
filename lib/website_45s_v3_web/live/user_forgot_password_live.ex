defmodule Website45sV3Web.UserForgotPasswordLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers,
    only: [authorize_email_send: 3, client_ip: 1, refuse_submit: 3]

  require Logger

  alias Website45sV3.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center mt-3">
        Forgot your password?
        <:subtitle>We'll send a password reset link to your inbox</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="reset_password_form"
        phx-submit="send_email"
        background_color="041624"
      >
        <.input
          field={@form[:email]}
          type="email"
          placeholder="Email"
          required
          background_color="041624"
        />
        <.turnstile id="forgot-password-turnstile" />
        <:actions>
          <.button phx-disable-with="Sending..." class="w-full green-button mt-1">
            Send reset instructions
          </.button>
        </:actions>
      </.simple_form>
      <p style="color:#d2e8f9;" class="text-center text-sm mt-1 li">
        <.link
          href={~p"/users/register"}
          class="font-semibold link"
          style="font-weight: bold; text-decoration: underline;"
        >
          Register
        </.link>
        |
        <.link
          href={~p"/users/log_in"}
          class="font-semibold link"
          style="font-weight: bold; text-decoration: underline;"
        >Log in</.link>
      </p>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:client_ip, client_ip(socket))
      |> assign(form: to_form(%{}, as: "user"))

    {:ok, socket}
  end

  def handle_event("send_email", %{"user" => %{"email" => email}} = params, socket) do
    case authorize_email_send(socket, params, email) do
      :ok ->
        if user = Accounts.get_user_by_email(email) do
          user
          |> Accounts.deliver_user_reset_password_instructions(
            &url(~p"/users/reset_password/#{&1}")
          )
          |> log_delivery_failure(user)
        end

        info =
          "If your email is in our system, you will receive instructions to reset your password shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> redirect(to: ~p"/")}

      {:error, reason} ->
        {:noreply,
         refuse_submit(socket, reason, "Too many requests. Please wait a while and try again.")}
    end
  end

  # The response must not reveal whether the address is registered, so a
  # delivery failure can only be logged, never shown.
  defp log_delivery_failure({:ok, _email}, _user), do: :ok

  defp log_delivery_failure({:error, reason}, user) do
    Logger.error("Could not send password reset email to user #{user.id}: #{inspect(reason)}")
  end
end
