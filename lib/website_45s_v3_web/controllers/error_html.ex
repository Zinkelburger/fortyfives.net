defmodule Website45sV3Web.ErrorHTML do
  @moduledoc """
  Renders the HTML error pages.

  The endpoint is configured with `render_errors: [layout: false]`, so the
  404 and 500 templates in `error_html/` are complete documents built by
  `error_page/1`. Any other status falls back to its plain status message.
  """
  use Website45sV3Web, :html

  embed_templates "error_html/*"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc """
  A self-contained error document in the site's navy palette, with the logo
  and links back home and to the lobby. Only inline styles are used because
  the app layout (and stylesheet) is not applied to error responses.
  """
  attr :status, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@title} | Forty Fives</title>
        <link rel="icon" type="image/svg+xml" href="/images/favicon.svg" />
        <link
          href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap"
          rel="stylesheet"
        />
        <style>
          * { box-sizing: border-box; }
          html, body { margin: 0; min-height: 100%; }
          body {
            display: flex;
            flex-direction: column;
            min-height: 100vh;
            background: #041624;
            color: #d2e8f9;
            font-family: 'Roboto', 'Helvetica', 'Arial', sans-serif;
          }
          .error-header {
            background: #071f31;
            border-bottom: 2px solid #d2e8f9;
            padding: 0.5rem 1rem;
          }
          .error-header img { display: block; width: min(260px, 60vw); height: auto; }
          main {
            flex: 1;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            text-align: center;
            padding: 2rem 1rem;
          }
          .error-status {
            margin: 0;
            font-size: clamp(4rem, 15vw, 7rem);
            font-weight: 700;
            line-height: 1;
            color: #81cbf8;
          }
          h1 { margin: 0.75rem 0 1rem; font-size: clamp(1.5rem, 5vw, 2.25rem); font-weight: 500; }
          .error-message { max-width: 32rem; margin: 0 0 1.5rem; font-size: 1.1rem; line-height: 1.5; }
          .error-actions { display: flex; flex-wrap: wrap; justify-content: center; gap: 1rem; }
          .error-actions a {
            display: inline-block;
            padding: 0.6rem 1.4rem;
            border: 2px solid #d2e8f9;
            border-radius: 10px;
            background: #071f31;
            color: #d2e8f9;
            font-weight: 500;
            text-decoration: none;
          }
          .error-actions a.primary { background: #81cbf8; border-color: #81cbf8; color: #040b12; }
          .error-actions a:hover, .error-actions a:focus-visible { text-decoration: underline; }
        </style>
      </head>
      <body>
        <header class="error-header">
          <a href="/"><img src="/images/noBlue.png" alt="Forty Fives" /></a>
        </header>
        <main>
          <p class="error-status" aria-hidden="true">{@status}</p>
          <h1>{@title}</h1>
          <p class="error-message">{render_slot(@inner_block)}</p>
          <nav class="error-actions" aria-label="Error page">
            <a href="/">Home</a>
            <a class="primary" href="/play">Play 45s</a>
          </nav>
        </main>
      </body>
    </html>
    """
  end
end
