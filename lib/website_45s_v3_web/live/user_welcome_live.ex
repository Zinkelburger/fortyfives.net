defmodule Website45sV3Web.UserWelcomeLive do
  @moduledoc """
  Offers a Google sign-up, who was given a random `player_xxxxxxx` name, the
  chance to pick the name other players see. Shown once: saving or keeping
  the generated name clears `username_pending`, and the lobby pages stop
  sending them here (`UserAuth.on_mount(:offer_username, ...)`). Settings
  keeps its own username form for later changes.
  """
  use Website45sV3Web, :live_view

  alias Website45sV3.Accounts
  alias Website45sV3.Security.RateLimiter

  def render(assigns) do
    ~H"""
    <.header class="text-center mx-auto max-w-[400px] mt-3">
      Welcome to Forty-Fives
      <:subtitle>Pick the name other players see at the table.</:subtitle>
    </.header>
    <div class="welcome-card mx-auto max-w-[400px]">
      <.simple_form for={@form} id="welcome_form" phx-submit="save" phx-change="validate">
        <div style="padding-top: 5px;">
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            required
            autofocus
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            phx-debounce="400"
            background_color="071f31"
          />
        </div>
        <:actions>
          <.button phx-disable-with="Saving..." class="w-full green-button">
            {if String.starts_with?(@return_to, "/play"), do: "Save and play", else: "Save"}
          </.button>
        </:actions>
        <:actions>
          <button type="button" id="keep_username" phx-click="keep" class="welcome-keep">
            Keep {@current_user.username}
          </button>
        </:actions>
      </.simple_form>
      <p class="welcome-note">
        You can change it any time in <.link navigate={~p"/users/settings"} class="welcome-note-link">Settings</.link>.
      </p>
    </div>
    """
  end

  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    return_to = safe_return_to(params["return_to"])

    if user.username_pending do
      {:ok,
       assign(socket,
         return_to: return_to,
         page_title: "Pick your name",
         form: to_form(Accounts.change_user_username(user, %{"username" => ""}))
       )}
    else
      {:ok, redirect(socket, to: return_to)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    form =
      socket.assigns.current_user
      |> Accounts.change_user_username(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => %{"username" => username}}, socket)
      when username == socket.assigns.current_user.username do
    handle_event("keep", %{}, socket)
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.current_user
    changeset = Accounts.change_user_username(user, user_params)

    # Same order as the settings form: a typo does not spend the budget.
    with true <- changeset.valid? || {:error, Map.put(changeset, :action, :insert)},
         :ok <- RateLimiter.check_username_change(user.id),
         {:ok, user} <- Accounts.update_user_username(user, user_params) do
      {:noreply,
       socket
       |> put_flash(:info, "You're playing as #{user.username}.")
       |> redirect(to: socket.assigns.return_to)}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You have changed your username too often. Try again tomorrow, or keep this one for now."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("keep", _params, socket) do
    {:ok, _user} = Accounts.keep_username(socket.assigns.current_user)
    {:noreply, redirect(socket, to: socket.assigns.return_to)}
  end

  # Only the lobby pages send people here, so only they are accepted back;
  # anything else (another site, a path we did not issue) goes home.
  defp safe_return_to(path) when path in ["/", "/play", "/learn"], do: path

  defp safe_return_to("/play/private/" <> id = path) do
    if id =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/, do: path, else: ~p"/"
  end

  defp safe_return_to(_path), do: ~p"/"
end
