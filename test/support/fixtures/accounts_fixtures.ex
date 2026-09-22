defmodule Website45sV3.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Website45sV3.Accounts` context.
  """

  alias Website45sV3.Accounts.User
  alias Website45sV3.Repo

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def unique_username, do: "user#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_username(),
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Website45sV3.Accounts.register_user()

    user
  end

  def confirmed_user_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> User.confirm_changeset()
    |> Repo.update!()
  end

  @doc """
  A `Ueberauth.Auth` as `ueberauth_google` would assign it after a successful
  Google callback. Options: `:email`, `:uid`, `:email_verified` (default true).
  """
  def google_auth(attrs \\ %{}) do
    attrs = Map.new(attrs)
    email = Map.get(attrs, :email, unique_user_email())
    uid = Map.get(attrs, :uid, "google-#{System.unique_integer([:positive])}")

    raw_user =
      %{"sub" => uid, "email" => email, "email_verified" => Map.get(attrs, :email_verified, true)}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %Ueberauth.Auth{
      provider: :google,
      strategy: Ueberauth.Strategy.Google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email},
      credentials: %Ueberauth.Auth.Credentials{},
      extra: %Ueberauth.Auth.Extra{raw_info: %{token: nil, user: raw_user}}
    }
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end
end
