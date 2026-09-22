# Website structure

Routes as declared in `lib/website_45s_v3_web/router.ex`. Every route goes
through the `:browser` pipeline: session, CSRF protection, a Content Security
Policy with a per-request nonce, the current-user lookup and a per-session
anonymous `user_id` (so anonymous visitors can queue and play).

## Playing

| Path | Module | Notes |
| --- | --- | --- |
| `/` | `HomeLive` | Landing page |
| `/learn` | `LearnLive` | Rules and a walkthrough of playing online |
| `/play` | `QueueLive` (`:new`) | Public matchmaking queue; `?tab=private` opens the "Play a Friend" tab. Bots can be added to fill seats. |
| `/play/private/:id` | `QueueLive` (`:private_game`) | A private lobby; the link is what players share. Canonicalises to `/play` and is not indexed. |
| `/game/:id` | `GameLive` | The game table. Lives in its own `live_session` with the `game_root` layout (no site navigation). |

Anonymous and signed-in players use the same routes; a signed-in player's
username is shown instead of "Anonymous".

## Accounts

| Path | Module | Notes |
| --- | --- | --- |
| `/users/register` | `UserRegistrationLive` | Redirects home when already signed in |
| `/users/log_in` (GET) | `UserLoginLive` | Redirects home when already signed in |
| `/users/log_in` (POST) | `UserSessionController.create` | Password login |
| `/users/log_out` (DELETE) | `UserSessionController.delete` | |
| `/users/reset_password` | `UserForgotPasswordLive` | Request a reset email |
| `/users/reset_password/:token` | `UserResetPasswordLive` | |
| `/users/confirm` | `UserConfirmationInstructionsLive` | Resend confirmation email |
| `/users/confirm/:token` | `UserConfirmationLive` | |
| `/users/settings` | `UserSettingsLive` (`:edit`) | Requires a signed-in user |
| `/users/settings/confirm_email/:token` | `UserSettingsLive` (`:confirm_email`) | Requires a signed-in user |
| `/auth/:provider` | `AuthController.request` | OAuth sign-in via Ueberauth (Google) |
| `/auth/:provider/callback` | `AuthController.callback` | |

## Operations

| Path | Notes |
| --- | --- |
| `/healthz` | Health check for the container / load balancer |
| `/dev/dashboard` | Phoenix LiveDashboard, development only (`dev_routes`) |
| `/dev/mailbox` | Bamboo sent-email viewer, development only |

## Static files and errors

`/assets/*`, `/images/*`, `/fonts/*`, `/favicon.ico`, `/robots.txt` and
`/sitemap.xml` are served from `priv/static` (see `Website45sV3Web.static_paths/0`).
Unknown paths and server errors render the styled pages in
`lib/website_45s_v3_web/controllers/error_html/`.
