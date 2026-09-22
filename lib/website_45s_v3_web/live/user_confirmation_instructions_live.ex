defmodule Website45sV3Web.UserConfirmationInstructionsLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers,
    only: [authorize_email_send: 3, client_ip: 1, refuse_submit: 3]

  require Logger

  alias Website45sV3.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        No confirmation instructions received?
        <:subtitle>We'll send a new confirmation link to your inbox</:subtitle>
      </.header>

      <.simple_form for={@form} id="resend_confirmation_form" phx-submit="send_instructions">
        <.input field={@form[:email]} type="email" placeholder="Email" required />
        <.turnstile id="resend-confirmation-turnstile" />
        <:actions>
          <.button phx-disable-with="Sending..." class="green-button w-full">
            Resend confirmation instructions
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center mt-4">
        <.link href={~p"/users/register"}>Register</.link>
        | <.link href={~p"/users/log_in"}>Log in</.link>
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

  def handle_event("send_instructions", %{"user" => %{"email" => email}} = params, socket) do
    case authorize_email_send(socket, params, email) do
      :ok ->
        if user = Accounts.get_user_by_email(email) do
          user
          |> Accounts.deliver_user_confirmation_instructions(&url(~p"/users/confirm/#{&1}"))
          |> log_delivery_failure(user)
        end

        info =
          "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> redirect(to: ~p"/")}

      {:error, reason} ->
        {:noreply,
         refuse_submit(socket, reason, "Too many requests. Please wait a while and try again.")}
    end
  end

  # The response must not reveal whether the address is registered (or
  # already confirmed), so a delivery failure can only be logged.
  defp log_delivery_failure({:ok, _email}, _user), do: :ok
  defp log_delivery_failure({:error, :already_confirmed}, _user), do: :ok

  defp log_delivery_failure({:error, reason}, user) do
    Logger.error("Could not send confirmation email to user #{user.id}: #{inspect(reason)}")
  end
end
