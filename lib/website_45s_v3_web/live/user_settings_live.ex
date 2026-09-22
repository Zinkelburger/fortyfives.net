defmodule Website45sV3Web.UserSettingsLive do
  use Website45sV3Web, :live_view

  import Website45sV3Web.AuthLiveHelpers, only: [password_field: 1]

  require Logger

  alias Website45sV3.Accounts

  def render(assigns) do
    ~H"""
    <div
      class="space-y-12 divide-y mx-auto max-w-sm mb-10"
      style="border: 2px solid #d2e8f9; border-radius: 10px; padding:10px; background-color: #071f31; margin-top: 35px;"
    >
      <div style="border-bottom; 0px;">
        <p style="color: #d2e8f9">
          Change your email
        </p>
        <.simple_form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label="New Email"
            required
            background_color="071f31"
          />
          <.password_field
            field={@email_form[:current_password]}
            name="current_password"
            id="current_password_for_email"
            label="Current password"
            autocomplete="current-password"
            phx-debounce="blur"
            required
          />
          <:actions>
            <.button
              phx-disable-with="Changing..."
              class="w-full green-button"
              style="margin-top: 10px;"
            >
              Change Email
            </.button>
          </:actions>
        </.simple_form>
      </div>
      <div style="margin-top: 0px;">
        <p style="color: #d2e8f9; margin-bottom: 20px; margin-top: 5px;">
          Change your password
        </p>
        <.simple_form
          for={@password_form}
          id="password_form"
          action={~p"/users/log_in?_action=password_updated"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="post_auth_token" value={@post_auth_token} />
          <.input
            field={@password_form[:email]}
            type="hidden"
            id="hidden_user_email"
            value={@current_email}
          />
          <.password_field
            field={@password_form[:password]}
            label="New password"
            autocomplete="new-password"
            required
          />
          <.password_field
            field={@password_form[:password_confirmation]}
            label="Confirm new password"
            autocomplete="new-password"
          />
          <.password_field
            field={@password_form[:current_password]}
            name="current_password"
            id="current_password_for_password"
            label="Current password"
            autocomplete="current-password"
            phx-debounce="blur"
            required
          />
          <:actions>
            <.button
              phx-disable-with="Changing..."
              class="w-full green-button"
              style="margin-top: 10px; margin-bottom: 4px;"
            >
              Change Password
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_user, token) do
        :ok ->
          put_flash(socket, :info, "Email changed successfully.")

        :error ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  # Passwords typed into the forms are never stored in assigns: the inputs
  # keep their own value in the browser (see `password_field/1`) and reach
  # this process only when a form is submitted or validated.
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    email_changeset = Accounts.change_user_email(user)
    password_changeset = Accounts.change_user_password(user)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:post_auth_token, nil)

    {:ok, socket}
  end

  def handle_event("validate_email", %{"user" => user_params}, socket) do
    email_form =
      socket.assigns.current_user
      |> Accounts.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    with {:ok, applied_user} <- Accounts.apply_user_email(user, password, user_params),
         {:ok, _email} <-
           Accounts.deliver_user_update_email_instructions(
             applied_user,
             user.email,
             &url(~p"/users/settings/confirm_email/#{&1}")
           ) do
      info = "A link to confirm your email change has been sent to the new address."
      {:noreply, put_flash(socket, :info, info)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}

      {:error, reason} ->
        Logger.error(
          "Could not send email-change instructions to user #{user.id}: #{inspect(reason)}"
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           "We could not send a confirmation link to the new address. Please try again later."
         )}
    end
  end

  def handle_event("validate_password", %{"user" => user_params}, socket) do
    password_form =
      socket.assigns.current_user
      |> Accounts.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    case Accounts.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Accounts.change_user_password(user_params)
          |> to_form()

        post_auth_token = Phoenix.Token.sign(socket, "post-auth", {:password_updated, user.id})

        {:noreply,
         assign(socket,
           trigger_submit: true,
           password_form: password_form,
           post_auth_token: post_auth_token
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end
end
