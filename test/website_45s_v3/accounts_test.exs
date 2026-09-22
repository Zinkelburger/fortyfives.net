defmodule Website45sV3.AccountsTest do
  use Website45sV3.DataCase

  alias Website45sV3.Accounts

  import Website45sV3.AccountsFixtures
  alias Website45sV3.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email and password to be set" do
      {:error, changeset} = Accounts.register_user(%{username: "tester"})

      assert %{
               password: ["can't be blank"],
               email: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates email and password when given" do
      {:error, changeset} =
        Accounts.register_user(%{
          username: "tester",
          email: "not valid",
          password: "short"
        })

      assert %{
               email: ["Must have the @ sign and no spaces"],
               password: ["should be at least 8 character(s)"]
             } = errors_on(changeset)
    end

    test "validates maximum values for email and password for security" do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.register_user(%{username: "tester", email: too_long, password: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "rejects control characters and whitespace in usernames" do
      # "trailing\n" is the case the old `^…$` anchors let through: in PCRE `$`
      # also matches immediately before a final newline.
      for username <- [
            "line\nbreak",
            "tab\tname",
            "space name",
            "ansi\e[31m",
            "trailing\n",
            "\nleading"
          ] do
        {:error, changeset} = Accounts.register_user(valid_user_attributes(username: username))
        assert errors_on(changeset).username != []
      end
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()

      {:error, changeset} =
        Accounts.register_user(valid_user_attributes(email: email, username: unique_username()))

      assert "has already been taken" in errors_on(changeset).email

      # Now try with the upper cased email too, to check that email case is ignored.
      {:error, changeset} =
        Accounts.register_user(
          valid_user_attributes(email: String.upcase(email), username: unique_username())
        )

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "change_user_registration/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_registration(%User{})
      assert Enum.sort(changeset.required) == [:email, :password, :username]
    end

    test "allows fields to be set" do
      email = unique_user_email()
      username = unique_username()
      password = valid_user_password()

      changeset =
        Accounts.change_user_registration(
          %User{},
          valid_user_attributes(email: email, username: username, password: password)
        )

      assert changeset.valid?
      assert get_change(changeset, :email) == email
      assert get_change(changeset, :username) == username
      assert get_change(changeset, :password) == password
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "apply_user_email/3" do
    setup do
      %{user: user_fixture()}
    end

    test "requires email to change", %{user: user} do
      {:error, changeset} = Accounts.apply_user_email(user, valid_user_password(), %{})
      assert %{email: ["Did not change"]} = errors_on(changeset)
    end

    test "validates email", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: "not valid"})

      assert %{email: ["Must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum value for email for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness", %{user: user} do
      %{email: email} = user_fixture()
      password = valid_user_password()

      {:error, changeset} = Accounts.apply_user_email(user, password, %{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, "invalid", %{email: unique_user_email()})

      assert %{current_password: ["Is not valid"]} = errors_on(changeset)
    end

    test "applies the email without persisting it", %{user: user} do
      email = unique_user_email()
      {:ok, user} = Accounts.apply_user_email(user, valid_user_password(), %{email: email})
      assert user.email == email
      assert Accounts.get_user!(user.id).email != email
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert Accounts.update_user_email(user, token) == :ok
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      assert changed_user.confirmed_at
      assert changed_user.confirmed_at != user.confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.update_user_email(user, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(%User{}, %{
          "password" => "new valid password"
        })

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "short",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 8 character(s)"],
               password_confirmation: ["Does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, "invalid", %{password: valid_user_password()})

      assert %{current_password: ["Is not valid"]} = errors_on(changeset)
    end

    test "updates the password", %{user: user} do
      {:ok, user} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "confirm"
    end
  end

  describe "confirm_user/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.confirmed_at != user.confirmed_at
      assert Repo.get!(User, user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Accounts.confirm_user("oops") == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.confirm_user(token) == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "reset_password"
    end
  end

  describe "get_user_by_reset_password_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "returns the user with valid token", %{user: %{id: id}, token: token} do
      assert %User{id: ^id} = Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: id)
    end

    test "does not return the user with invalid token", %{user: user} do
      refute Accounts.get_user_by_reset_password_token("oops")
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not return the user if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "reset_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.reset_user_password(user, %{
          password: "short",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 8 character(s)"],
               password_confirmation: ["Does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.reset_user_password(user, %{password: too_long})
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, updated_user} = Accounts.reset_user_password(user, %{password: "new valid password"})
      assert is_nil(updated_user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "disconnects the LiveView sockets of every session", %{user: user} do
      topic = user |> Accounts.generate_user_session_token() |> Accounts.live_socket_id()
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, topic)

      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end
  end

  describe "update_user_username/2" do
    test "changes the username with the registration checks" do
      user = user_fixture()
      taken = user_fixture()

      assert {:ok, %{username: "brand_new_name"}} =
               Accounts.update_user_username(user, %{username: "brand_new_name"})

      assert {:error, changeset} =
               Accounts.update_user_username(user, %{username: taken.username})

      assert "has already been taken" in errors_on(changeset).username

      assert {:error, changeset} = Accounts.update_user_username(user, %{username: "x"})
      assert errors_on(changeset).username != []
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "username screening" do
    test "rejects a trailing newline in the email" do
      # `$` matched before a final newline; `\z` does not.
      {:error, changeset} =
        Accounts.register_user(valid_user_attributes(email: "user@example.com\n"))

      assert "Must have the @ sign and no spaces" in errors_on(changeset).email
    end

    test "ordinary names that merely contain a banned substring are allowed" do
      for username <- ~w(Cassidy Massachusetts Saturday cucumber Hancock Kumar translate
                         badminton button raccoon assassin player1 Cummings analyst) do
        refute User.banned_username?(username), "#{username} should be allowed"
        assert User.valid_username?(username), "#{username} should be valid"
      end
    end

    test "banned words are caught as whole names and whole words" do
      for username <- ~w(fuck Fuck FUCK xx_fuck_xx fuck.you nigger-1 admin Admin admin_bob
                         moderator fortyfives fuck123 ass a_s_s) do
        assert User.banned_username?(username), "#{username} should be banned"
      end
    end

    test "separator, confusable, fullwidth, diacritic and leet spellings are caught" do
      for username <- [
            "f.u.c.k",
            "f-u-c-k",
            "f_u_c_k",
            # Cyrillic с and о
            "fuсk",
            "cоck",
            # fullwidth
            "ｆｕｃｋ",
            "fück",
            "sh1t",
            "a55hole",
            "nigg3r",
            "n1gga",
            "f4ggot"
          ] do
        assert User.banned_username?(username), "#{username} should be banned"
      end
    end

    test "registration reports a banned word" do
      {:error, changeset} = Accounts.register_user(valid_user_attributes(username: "f.u.c.k"))
      assert "Contains a banned word" in errors_on(changeset).username
    end

    test "the reserved-name screen does not block names that only contain them" do
      assert User.valid_username?("badminton")
      assert User.valid_username?("nomads")
      assert User.valid_username?("rootbeer")
    end
  end

  describe "unique constraints" do
    test "a username collision that slips past the pre-check is a form error, not a crash" do
      %{username: username} = user_fixture()

      {:error, changeset} =
        %User{}
        |> User.registration_changeset(
          valid_user_attributes(username: username),
          validate_username: false
        )
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).username
    end

    test "linking an already-linked Google account is a form error, not a crash" do
      {:ok, first} = Accounts.get_or_create_google_user(google_auth(uid: "google-taken"))
      assert first.google_uid == "google-taken"

      {:error, changeset} =
        user_fixture()
        |> User.google_link_changeset("google-taken")
        |> Repo.update()

      assert "has already been taken" in errors_on(changeset).google_uid
    end

    test "linking a Google account never confirms the user" do
      user = user_fixture()
      Repo.update!(Ecto.Changeset.change(user, confirmed_at: nil))

      {:ok, linked} = user |> User.google_link_changeset("google-unconfirmed") |> Repo.update()

      assert linked.google_uid == "google-unconfirmed"
      refute linked.confirmed_at
      refute Repo.get!(User, user.id).confirmed_at
    end
  end

  describe "random_username/0" do
    test "is a valid player name, unrelated to any email" do
      username = Accounts.random_username()
      assert "player_" <> _ = username
      assert User.valid_username?(username)
      assert String.length(username) <= 30
    end
  end

  describe "get_or_create_google_user/1" do
    test "creates a confirmed user with a random username for a new verified email" do
      auth = google_auth(email: "newcomer@example.com", uid: "google-new")

      assert {:ok, user} = Accounts.get_or_create_google_user(auth)
      assert user.email == "newcomer@example.com"
      # Never the email's local part: usernames are public.
      assert "player_" <> _ = user.username
      assert user.google_uid == "google-new"
      assert user.confirmed_at
      assert is_binary(user.hashed_password)
    end

    test "returns the already-linked user for a known uid" do
      auth = google_auth(uid: "google-known")
      {:ok, user} = Accounts.get_or_create_google_user(auth)

      assert {:ok, %User{id: id}} = Accounts.get_or_create_google_user(auth)
      assert id == user.id
      assert Repo.aggregate(User, :count) == 1
    end

    test "links to a confirmed local account with the same email" do
      user = confirmed_user_fixture()
      auth = google_auth(email: user.email, uid: "google-link")

      assert {:ok, linked} = Accounts.get_or_create_google_user(auth)
      assert linked.id == user.id
      assert linked.google_uid == "google-link"
      assert Repo.aggregate(User, :count) == 1
    end

    test "matches the local email case-insensitively" do
      user = confirmed_user_fixture(email: "Mixed.Case@example.com")
      auth = google_auth(email: "mixed.case@example.com")

      assert {:ok, linked} = Accounts.get_or_create_google_user(auth)
      assert linked.id == user.id
    end

    test "refuses to link to an unconfirmed local account" do
      user = user_fixture()
      refute user.confirmed_at

      auth = google_auth(email: user.email, uid: "google-squat")

      assert {:error, :unconfirmed_account} = Accounts.get_or_create_google_user(auth)
      assert Accounts.get_user!(user.id).google_uid == nil
      refute Accounts.get_user_by_google_uid("google-squat")
    end

    test "refuses an email Google has not verified, even for a confirmed account" do
      user = confirmed_user_fixture()
      auth = google_auth(email: user.email, uid: "google-unverified", email_verified: false)

      assert {:error, :email_unverified} = Accounts.get_or_create_google_user(auth)
      assert Accounts.get_user!(user.id).google_uid == nil
      assert Repo.aggregate(User, :count) == 1
    end

    test "refuses when the verified flag is absent from the raw profile" do
      auth = google_auth(email: unique_user_email(), email_verified: nil)
      assert {:error, :email_unverified} = Accounts.get_or_create_google_user(auth)
      assert Repo.aggregate(User, :count) == 0
    end

    test "refuses when Google shares no email" do
      auth = google_auth(email: nil)
      assert {:error, :email_missing} = Accounts.get_or_create_google_user(auth)

      auth = google_auth(email: "   ")
      assert {:error, :email_missing} = Accounts.get_or_create_google_user(auth)

      assert Repo.aggregate(User, :count) == 0
    end

    test "refuses when the email is already linked to a different Google account" do
      user = confirmed_user_fixture()
      {:ok, _} = Accounts.get_or_create_google_user(google_auth(email: user.email, uid: "g-one"))

      assert {:error, :google_account_mismatch} =
               Accounts.get_or_create_google_user(google_auth(email: user.email, uid: "g-two"))

      assert Accounts.get_user!(user.id).google_uid == "g-one"
    end
  end

  describe "purge_expired_tokens/0" do
    setup do
      %{user: user_fixture()}
    end

    defp age_tokens(days) do
      Repo.update_all(UserToken,
        set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -days * 86_400, :second)]
      )
    end

    test "deletes tokens past their context's validity and keeps the rest", %{user: user} do
      # Every context, aged past its own limit.
      _ = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.deliver_user_confirmation_instructions(user, & &1)
      {:ok, _} = Accounts.deliver_user_reset_password_instructions(user, & &1)
      {:ok, _} = Accounts.deliver_user_update_email_instructions(user, "old@example.com", & &1)
      age_tokens(61)

      # Fresh ones that must survive.
      live_session = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.deliver_user_reset_password_instructions(user, & &1)

      assert Accounts.purge_expired_tokens() == 4
      assert Repo.aggregate(UserToken, :count) == 2
      assert Accounts.get_user_by_session_token(live_session)
    end

    test "respects each context's own validity window", %{user: user} do
      # 2 days: a reset-password token (1 day) has expired, a session (60 days)
      # and a confirmation token (7 days) have not.
      _ = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.deliver_user_confirmation_instructions(user, & &1)
      {:ok, _} = Accounts.deliver_user_reset_password_instructions(user, & &1)
      age_tokens(2)

      assert Accounts.purge_expired_tokens() == 1
      refute Repo.get_by(UserToken, context: "reset_password")
      assert Repo.get_by(UserToken, context: "session")
      assert Repo.get_by(UserToken, context: "confirm")
    end

    test "is a no-op with nothing expired", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      assert Accounts.purge_expired_tokens() == 0
      assert Repo.aggregate(UserToken, :count) == 1
    end
  end

  describe "TokenSweeper" do
    alias Website45sV3.Accounts.TokenSweeper

    test "purges on each sweep tick" do
      user = user_fixture()
      _ = Accounts.generate_user_session_token(user)
      age_tokens(61)
      _ = Accounts.generate_user_session_token(user)

      pid =
        start_supervised!(
          {TokenSweeper, name: :test_token_sweeper, initial_delay_ms: :timer.hours(1)}
        )

      # Nothing has run yet.
      assert TokenSweeper.last_purged(pid) == nil
      assert Repo.aggregate(UserToken, :count) == 2

      send(pid, :sweep)
      assert TokenSweeper.last_purged(pid) == 1
      assert Repo.aggregate(UserToken, :count) == 1
    end
  end
end
