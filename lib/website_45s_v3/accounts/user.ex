defmodule Website45sV3.Accounts.User do
  @moduledoc """
  The user schema and its changesets.

  Usernames are screened against `priv/banned_words.txt`. The screen is
  deliberately narrow: a banned term only matches a *whole* username or a
  whole separator-delimited word inside it (so "Cassidy", "Hancock" and
  "Saturday" pass), but the name is first normalised — NFKC/NFKD folding,
  diacritics stripped, common Unicode confusables and leet digits mapped back
  to ASCII, separators removed — so "f.u.c.k", "ｆｕｃｋ", "fuсk" (Cyrillic с)
  and "sh1t" all still match.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @banned_words_path Application.app_dir(:website_45s_v3, "priv/banned_words.txt")
  @external_resource @banned_words_path
  @banned_words @banned_words_path
                |> File.read!()
                |> String.split("\n")
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
                |> Enum.map(&String.downcase/1)
                |> MapSet.new()

  # Look-alike characters folded to the ASCII letter they imitate. Cyrillic,
  # Greek and a few Latin variants that render identically or near-identically
  # in most fonts.
  @confusables %{
    # Cyrillic
    "а" => "a",
    "в" => "b",
    "е" => "e",
    "ё" => "e",
    "з" => "3",
    "і" => "i",
    "ї" => "i",
    "ј" => "j",
    "к" => "k",
    "м" => "m",
    "н" => "h",
    "о" => "o",
    "р" => "p",
    "с" => "c",
    "т" => "t",
    "у" => "y",
    "х" => "x",
    "ѕ" => "s",
    "һ" => "h",
    "ԁ" => "d",
    "ѡ" => "w",
    "ⅼ" => "l",
    # Greek
    "α" => "a",
    "β" => "b",
    "ε" => "e",
    "η" => "n",
    "ι" => "i",
    "κ" => "k",
    "ν" => "v",
    "ο" => "o",
    "ρ" => "p",
    "τ" => "t",
    "υ" => "u",
    "χ" => "x",
    # Latin variants
    "ı" => "i",
    "ł" => "l",
    "ø" => "o",
    "ß" => "ss",
    "æ" => "ae",
    "œ" => "oe"
  }

  @leet %{"0" => "o", "1" => "i", "3" => "e", "4" => "a", "5" => "s"}

  @separators ~r/[._\-\s]+/u

  schema "users" do
    field :username, :string
    field :email, :string
    field :google_uid, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :naive_datetime

    timestamps()
  end

  @doc """
  A user changeset for registration.

  It is important to validate the length of both email and password.
  Otherwise databases may truncate the email without warnings, which
  could lead to unpredictable or insecure behaviour. Long passwords may
  also be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_email` - Validates the uniqueness of the email, in case
      you don't want to validate the uniqueness of the email (like when
      using this changeset for validations on a LiveView form before
      submitting the form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_username` - Same as `:validate_email`, for the username.
      Defaults to `true`.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :password, :username])
    |> validate_email(opts)
    |> validate_password(opts)
    |> validate_username(opts)
  end

  @doc """
  A username change. Same checks as at registration; `:validate_username`
  works the same way (pass `false` for per-keystroke validation).
  """
  def username_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username])
    |> validate_username(opts)
    |> case do
      %{changes: %{username: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :username, "did not change")
    end
  end

  @doc """
  Links a Google account to an existing user. Only ever applied to a
  confirmed account (`Accounts.get_or_create_google_user/1` refuses
  unconfirmed ones, since linking would let whoever holds the Google
  account claim a username someone else registered), so it does not touch
  `confirmed_at`.
  """
  def google_link_changeset(user, google_uid) when is_binary(google_uid) do
    user
    |> change(google_uid: google_uid)
    |> unique_constraint(:google_uid)
  end

  @doc """
  Reports whether `username` would pass every local (non-database) username
  check: presence, length, character set and the banned-word screen.
  """
  def valid_username?(username) do
    changeset =
      %__MODULE__{}
      |> cast(%{username: username}, [:username])
      |> validate_username(validate_username: false)

    changeset.valid?
  end

  @doc """
  Reports whether `username` matches the banned-word screen described in the
  module documentation.
  """
  def banned_username?(username) when is_binary(username) do
    folded = fold(username)
    whole = String.replace(folded, @separators, "")
    words = String.split(folded, @separators, trim: true)

    # A word such as "shit123" is caught by splitting on letter/digit
    # boundaries, while "sh1t" is caught by leet folding; both are tried.
    pieces =
      Enum.flat_map(words, fn word ->
        String.split(word, ~r/(?<=\p{L})(?=\p{N})|(?<=\p{N})(?=\p{L})/u, trim: true)
      end)

    ([whole, leet(whole)] ++ words ++ Enum.map(words, &leet/1) ++ pieces)
    |> Enum.any?(&MapSet.member?(@banned_words, &1))
  end

  def banned_username?(_), do: false

  defp fold(username) do
    username
    |> String.normalize(:nfkd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.graphemes()
    |> Enum.map_join(&Map.get(@confusables, &1, &1))
  end

  defp leet(word) do
    word
    |> String.graphemes()
    |> Enum.map_join(&Map.get(@leet, &1, &1))
  end

  defp validate_username(changeset, opts) do
    changeset
    |> validate_required([:username])
    |> validate_length(:username, min: 3)
    |> validate_length(:username, max: 30)
    |> validate_banned_words()
    # \A and \z, not ^ and $: `$` also matches before a trailing newline, so
    # the line anchors would let "name\n" through the control-character screen.
    |> validate_format(:username, ~r/\A[\p{L}\p{N}_.-]+\z/u,
      message: "May only contain letters, numbers, periods, underscores, and hyphens"
    )
    |> maybe_validate_unique_username(opts)
  end

  defp validate_banned_words(changeset) do
    username = get_field(changeset, :username)

    if banned_username?(username) do
      add_error(changeset, :username, "Contains a banned word")
    else
      changeset
    end
  end

  # The database constraint is always mapped to a form error; only the
  # pre-insert lookup is optional, since it is what leaks on a live form.
  defp maybe_validate_unique_username(changeset, opts) do
    changeset
    |> maybe_unsafe_validate_unique(:username, Keyword.get(opts, :validate_username, true))
    |> unique_constraint(:username)
  end

  defp maybe_validate_unique_email(changeset, opts) do
    changeset
    |> maybe_unsafe_validate_unique(:email, Keyword.get(opts, :validate_email, true))
    |> unique_constraint(:email)
  end

  defp maybe_unsafe_validate_unique(changeset, field, true) do
    unsafe_validate_unique(changeset, field, Website45sV3.Repo)
  end

  defp maybe_unsafe_validate_unique(changeset, _field, false), do: changeset

  defp validate_email(changeset, opts) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/\A[^\s]+@[^\s]+\z/,
      message: "Must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> maybe_validate_unique_email(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :email, "Did not change")
    end
  end

  @doc """
  A user changeset for changing the password.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "Does not match password")
    |> validate_password(opts)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Website45sV3.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Validates the current password otherwise adds an error to the changeset.
  """
  def validate_current_password(changeset, password) do
    if valid_password?(changeset.data, password) do
      changeset
    else
      add_error(changeset, :current_password, "Is not valid")
    end
  end
end
