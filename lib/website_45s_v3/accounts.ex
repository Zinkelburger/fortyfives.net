defmodule Website45sV3.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Website45sV3.Accounts.{User, UserNotifier, UserToken}
  alias Website45sV3.Repo

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = Repo.get_by(User, username: username)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  Uniqueness of the email and username is deliberately *not* checked here:
  this changeset runs on every keystroke of the registration form, unprotected
  by Turnstile or a rate limit, and an unthrottled "has already been taken"
  would let anyone enumerate accounts. Uniqueness is reported on submit by
  `register_user/1`.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs,
      hash_password: false,
      validate_email: false,
      validate_username: false
    )
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs, validate_email: false)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset =
      user
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm_email/#{&1})")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes every token that has expired and returns how many were removed.
  Run periodically by `Website45sV3.Accounts.TokenSweeper`.
  """
  def purge_expired_tokens do
    {count, _} = Repo.delete_all(UserToken.expired_query())
    count
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &url(~p"/users/confirm/#{&1}"))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset_password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Google sign-in

  def get_user_by_google_uid(uid) when is_binary(uid) do
    Repo.get_by(User, google_uid: uid)
  end

  @doc """
  Finds the user for a Google sign-in, linking or creating one as needed.

  A user already linked to the Google account (by `uid`) is returned as is.
  Otherwise the Google email is used, and only when Google itself reports it
  verified: an unverified address can be claimed by anyone with a Google
  account, so trusting it would hand over whichever local account shares it.
  Even a verified address is only auto-linked to a local account that has
  confirmed the same email; an unconfirmed local account may have been
  registered by someone else who guessed the address first, so linking it
  would let that someone into the newcomer's account with the password they
  chose. That case is refused and the user told to confirm or reset first.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is one of
  `:uid_missing`, `:email_missing`, `:email_unverified`, `:unconfirmed_account`,
  `:google_account_mismatch` (the email is confirmed and already linked to a
  *different* Google account) or an `Ecto.Changeset`.
  """
  def get_or_create_google_user(%Ueberauth.Auth{uid: uid, info: info} = auth) do
    email = info.email

    cond do
      not is_binary(uid) or uid == "" ->
        {:error, :uid_missing}

      user = get_user_by_google_uid(uid) ->
        {:ok, user}

      not is_binary(email) or String.trim(email) == "" ->
        {:error, :email_missing}

      not google_email_verified?(auth) ->
        {:error, :email_unverified}

      true ->
        link_or_create_google_user(uid, String.trim(email))
    end
  end

  defp google_email_verified?(%Ueberauth.Auth{extra: %Ueberauth.Auth.Extra{raw_info: raw_info}})
       when is_map(raw_info) do
    # ueberauth_google stores Google's userinfo document under `:user`; the
    # OpenID `email_verified` claim in it is what we need.
    case Map.get(raw_info, :user) || Map.get(raw_info, "user") do
      %{"email_verified" => true} -> true
      _ -> false
    end
  end

  defp google_email_verified?(_auth), do: false

  defp link_or_create_google_user(uid, email) do
    case get_user_by_email(email) do
      nil ->
        create_google_user(uid, email)

      %User{confirmed_at: nil} ->
        {:error, :unconfirmed_account}

      %User{google_uid: nil} = user ->
        user
        |> User.google_link_changeset(uid)
        |> Repo.update()

      %User{} ->
        {:error, :google_account_mismatch}
    end
  end

  # A username collision between choosing a name and inserting it surfaces
  # as a changeset error thanks to the unique constraint; retry with a fresh
  # random name rather than failing the sign-in.
  defp create_google_user(uid, email) do
    insert_google_user(uid, email, generate_username(email), 3)
  end

  defp insert_google_user(uid, email, username, attempts_left) do
    # The password is unguessable and never shown; a Google user who wants
    # password sign-in goes through "forgot password".
    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %User{}
    |> User.registration_changeset(%{email: email, username: username, password: password})
    |> Ecto.Changeset.change(google_uid: uid)
    |> User.confirm_changeset()
    |> Ecto.Changeset.unique_constraint(:google_uid)
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{errors: [username: _]}} when attempts_left > 1 ->
        insert_google_user(uid, email, random_username(), attempts_left - 1)

      result ->
        result
    end
  end

  @doc """
  Derives a valid, currently unused username from an email address.

  The local part is reduced to the characters usernames allow, truncated to
  fit, and given a numeric suffix if it is taken. When nothing usable is left
  (too short, a banned word, every suffix taken) a random `player_xxxx` name
  is used instead, so sign-up can never fail on the username alone.
  """
  def generate_username(email) when is_binary(email) do
    base =
      email
      |> String.split("@")
      |> hd()
      |> String.replace(~r/[^\p{L}\p{N}_.-]/u, "")
      |> String.slice(0, 30)

    if User.valid_username?(base) do
      first_available([base | Enum.map(2..20, &suffixed(base, &1))]) || random_username()
    else
      random_username()
    end
  end

  defp suffixed(base, n) do
    suffix = Integer.to_string(n)
    String.slice(base, 0, 30 - String.length(suffix)) <> suffix
  end

  defp first_available(candidates) do
    Enum.find(candidates, fn candidate ->
      User.valid_username?(candidate) and is_nil(get_user_by_username(candidate))
    end)
  end

  defp random_username do
    candidate =
      "player_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

    if get_user_by_username(candidate), do: random_username(), else: candidate
  end
end
