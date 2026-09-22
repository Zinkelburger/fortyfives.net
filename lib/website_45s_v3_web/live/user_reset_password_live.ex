defmodule Website45sV3Web.UserResetPasswordLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers, only: [password_field: 1]

  alias Website45sV3.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">Reset Password</.header>

      <.simple_form
        for={@form}
        id="reset_password_form"
        phx-submit="reset_password"
        phx-change="validate"
      >
        <.error :if={@form.errors != []}>
          Oops, something went wrong! Please check the errors below.
        </.error>

        <.password_field
          field={@form[:password]}
          label="New password"
          autocomplete="new-password"
          required
        />
        <.password_field
          field={@form[:password_confirmation]}
          label="Confirm new password"
          autocomplete="new-password"
          required
        />
        <:actions>
          <.button phx-disable-with="Resetting..." class="w-full">Reset Password</.button>
        </:actions>
      </.simple_form>

      <p class="text-center text-sm mt-4">
        <.link href={~p"/users/register"}>Register</.link>
        | <.link href={~p"/users/log_in"}>Log in</.link>
      </p>
    </div>
    """
  end

  def mount(params, _session, socket) do
    socket = assign_user_and_token(socket, params)

    form_source =
      case socket.assigns do
        %{user: user} ->
          Accounts.change_user_password(user)

        _ ->
          %{}
      end

    {:ok, assign_form(socket, form_source), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after reset password to avoid a
  # leaked token giving the user access to the account.
  #
  # The token is checked again here, not just at mount: the page may have
  # been left open past the token's lifetime, or the token invalidated in
  # the meantime (a newer reset, a completed reset, an email change).
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.get_user_by_reset_password_token(socket.assigns.token) do
      nil ->
        {:noreply, expired_token(socket)}

      user ->
        case Accounts.reset_user_password(user, user_params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Password reset successfully.")
             |> redirect(to: ~p"/users/log_in")}

          {:error, changeset} ->
            {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
        end
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_user_and_token(socket, %{"token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      assign(socket, user: user, token: token)
    else
      expired_token(socket)
    end
  end

  defp expired_token(socket) do
    socket
    |> put_flash(:error, "Reset password link is invalid or it has expired.")
    |> redirect(to: ~p"/")
  end

  defp assign_form(socket, %{} = source) do
    assign(socket, :form, to_form(source, as: "user"))
  end
end
