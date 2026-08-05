defmodule Website45sV3Web.UserConfirmationInstructionsLive do
  use Website45sV3Web, :live_view

  alias Website45sV3.Accounts
  alias Website45sV3.Turnstile

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
    case Turnstile.verify(params["cf-turnstile-response"], socket.assigns.client_ip) do
      :ok ->
        if user = Accounts.get_user_by_email(email) do
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )
        end

        info =
          "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> redirect(to: ~p"/")}

      {:error, :turnstile_failed} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please complete the verification challenge and try again.")
         |> push_event("turnstile:reset", %{})}
    end
  end

  defp client_ip(socket) do
    Turnstile.client_ip(
      get_connect_info(socket, :x_headers),
      get_connect_info(socket, :peer_data)
    )
  end
end
