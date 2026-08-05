defmodule Website45sV3.Accounts.UserNotifier do
  import Bamboo.Email
  alias Website45sV3.Mailer

  @logo_url "https://fortyfives.net/images/apple-touch-icon.png"
  @brand_red "#d21e2b"

  # Delivers the email using the application mailer (HTML body + plain-text fallback).
  defp deliver(recipient, subject, text_body, html_inner) do
    new_email(
      to: recipient,
      from: {"FortyFives", "noreply@fortyfives.net"},
      subject: subject,
      text_body: text_body,
      html_body: layout(html_inner)
    )
    |> Mailer.deliver_now()
  end

  # Wraps message content in a branded HTML shell with the FortyFives logo.
  defp layout(inner) do
    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      </head>
      <body style="background:#f4f4f5;margin:0;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
          <div style="text-align:center;padding:28px 24px 4px;">
            <img src="#{@logo_url}" alt="FortyFives" width="64" height="64" style="width:64px;height:64px;border:0;display:inline-block;" />
          </div>
          <div style="padding:12px 32px 28px;color:#18181b;font-size:15px;line-height:1.6;">
            #{inner}
          </div>
          <div style="background:#fafafa;border-top:1px solid #eeeeee;padding:16px 24px;text-align:center;color:#9ca3af;font-size:12px;">
            FortyFives.net &middot; the card game 45s
          </div>
        </div>
      </body>
    </html>
    """
  end

  # A branded call-to-action button plus a copy-paste link fallback.
  defp button(label, url) do
    """
    <p style="text-align:center;margin:28px 0;">
      <a href="#{url}" style="background:#{@brand_red};color:#ffffff;text-decoration:none;padding:12px 28px;border-radius:8px;font-weight:bold;display:inline-block;">#{label}</a>
    </p>
    <p style="color:#6b7280;font-size:13px;">Or paste this link into your browser:<br />
      <a href="#{url}" style="color:#{@brand_red};word-break:break-all;">#{url}</a>
    </p>
    """
  end

  defp greeting(email), do: "<p>Hi #{Plug.HTML.html_escape(email)},</p>"

  @doc """
  Deliver instructions to confirm account.
  """
  def deliver_confirmation_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.
    """

    html =
      greeting(user.email) <>
        "<p>Welcome to FortyFives! Confirm your account to start playing 45s.</p>" <>
        button("Confirm my account", url) <>
        "<p style=\"color:#6b7280;font-size:13px;\">If you didn't create an account with us, please ignore this email.</p>"

    deliver(user.email, "Confirmation instructions", text, html)
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.
    """

    html =
      greeting(user.email) <>
        "<p>We received a request to reset your password.</p>" <>
        button("Reset my password", url) <>
        "<p style=\"color:#6b7280;font-size:13px;\">If you didn't request this change, please ignore this email — your password will stay the same.</p>"

    deliver(user.email, "Reset password instructions", text, html)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.
    """

    html =
      greeting(user.email) <>
        "<p>Confirm this address to finish updating your FortyFives email.</p>" <>
        button("Confirm email change", url) <>
        "<p style=\"color:#6b7280;font-size:13px;\">If you didn't request this change, please ignore this email.</p>"

    deliver(user.email, "Update email instructions", text, html)
  end
end
