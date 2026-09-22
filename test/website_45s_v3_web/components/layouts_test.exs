defmodule Website45sV3Web.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Website45sV3Web.Layouts

  # Cloudflare Rocket Loader rewrites every executable <script> and loads it
  # through its own un-nonced loader, which our strict-dynamic CSP blocks, so
  # app.js never runs and LiveView never connects. data-cfasync="false" opts a
  # tag out; every executable script in a root layout needs it.
  for layout <- [:root, :game_root] do
    test "#{layout} opts every executable script out of Rocket Loader" do
      html =
        Layouts
        |> apply(unquote(layout), [
          %{inner_content: "", csp_nonce: "test-nonce", admin_assets: true}
        ])
        |> rendered_to_string()

      scripts =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s{script:not([type="application/ld+json"])})
        |> Enum.to_list()

      assert scripts != []

      for script <- scripts do
        assert LazyHTML.attribute(script, "data-cfasync") == ["false"], LazyHTML.to_html(script)
        assert LazyHTML.attribute(script, "nonce") == ["test-nonce"], LazyHTML.to_html(script)
      end
    end
  end
end
