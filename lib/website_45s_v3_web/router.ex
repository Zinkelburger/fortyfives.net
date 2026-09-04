defmodule Website45sV3Web.Router do
  use Website45sV3Web, :router

  import Website45sV3Web.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Website45sV3Web.Layouts, :root}
    plug :protect_from_forgery
    # `put_content_security_policy/2` below replaces this header with the real
    # nonce-bearing policy. The conservative default stays here anyway: it is
    # what a browser would get if that plug were ever dropped or reordered out
    # of the pipeline, and it is the form Sobelow's Config.CSP check reads.
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug :put_content_security_policy
    plug :fetch_current_user
    plug :potentially_anonymous_user
    plug :assign_canonical_path
  end

  defp put_content_security_policy(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    policy =
      [
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-ancestors 'self'",
        "form-action 'self'",
        "script-src 'self' 'nonce-#{nonce}' 'strict-dynamic' https://challenges.cloudflare.com",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' data: https://fonts.gstatic.com",
        "img-src 'self' data:",
        "connect-src 'self' wss://fortyfives.net wss://www.fortyfives.net wss://fortyfives.gigalixirapp.com wss://www.fortyfives.gigalixirapp.com https://challenges.cloudflare.com",
        # 'self' keeps Phoenix LiveReload's iframe working in dev; an explicit
        # frame-src is not backed by default-src, so omitting it blocked the
        # reloader silently.
        "frame-src 'self' https://challenges.cloudflare.com",
        "worker-src 'self' blob:",
        "manifest-src 'self'",
        "upgrade-insecure-requests"
      ]
      |> Enum.join("; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy)
  end

  #  Bamboo mailbox preview in development
  if Application.compile_env(:website_45s_v3, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Website45sV3Web.Telemetry
      forward "/mailbox", Bamboo.SentEmailViewerPlug
    end
  end

  scope "/auth", Website45sV3Web do
    pipe_through [:browser]

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  ## Authentication routes

  scope "/", Website45sV3Web do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{Website45sV3Web.UserAuth, :redirect_if_user_is_authenticated}] do
      live "/users/register", UserRegistrationLive, :new
      live "/users/log_in", UserLoginLive, :new
      live "/users/reset_password", UserForgotPasswordLive, :new
      live "/users/reset_password/:token", UserResetPasswordLive, :edit
    end

    post "/users/log_in", UserSessionController, :create
  end

  scope "/", Website45sV3Web do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{Website45sV3Web.UserAuth, :ensure_authenticated}] do
      live "/users/settings", UserSettingsLive, :edit
      live "/users/settings/confirm_email/:token", UserSettingsLive, :confirm_email
    end
  end

  scope "/", Website45sV3Web do
    pipe_through [:browser]

    # default session for “play”
    live_session :default,
      on_mount: [{Website45sV3Web.UserAuth, :potentially_anonymous_user}],
      root_layout: {Website45sV3Web.Layouts, :root} do
      live "/", HomeLive, :index
      live "/learn", LearnLive, :index
      live "/play", QueueLive, :new
      live "/play/private/:id", QueueLive, :private_game
    end

    # separate session for “game” with its own root layout
    live_session :game,
      on_mount: [{Website45sV3Web.UserAuth, :potentially_anonymous_user}],
      root_layout: {Website45sV3Web.Layouts, :game_root} do
      live "/game/:id", GameLive, :new
    end
  end

  scope "/", Website45sV3Web do
    pipe_through [:browser]

    delete "/users/log_out", UserSessionController, :delete

    live_session :current_user,
      on_mount: [{Website45sV3Web.UserAuth, :mount_current_user}] do
      live "/users/confirm/:token", UserConfirmationLive, :edit
      live "/users/confirm", UserConfirmationInstructionsLive, :new
    end
  end
end
