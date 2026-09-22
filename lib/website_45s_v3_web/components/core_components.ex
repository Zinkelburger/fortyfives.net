defmodule Website45sV3Web.CoreComponents do
  @moduledoc """
  Core UI components: flash messages, forms and inputs, buttons, page headers
  and the Cloudflare Turnstile widget, styled for the site's navy palette.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component
  use Gettext, backend: Website45sV3Web.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  # Flashes that must stay on screen until the player dismisses them.
  @persistent_messages [
    "You took too long. A bot is playing for you.",
    "Welcome back! A bot was playing for you when you left. Auto-play has been disabled."
  ]

  @doc """
  Renders flash notices.

  Visible flashes drain a progress bar and dismiss themselves (see the
  `AutoDismissFlash` hook) unless the message is one a player must act on.
  Pass `auto_dismiss={false}` for flashes that are shown and hidden by other
  means, such as the connection-lost notices in `flash_group/1`.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash-info")}>Welcome Back!</.flash>
  """
  attr :id, :string, default: nil, doc: "the id of the flash container, defaults to flash-<kind>"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :auto_dismiss, :boolean, default: true, doc: "dismiss the flash after a short delay"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    persistent? = Phoenix.Flash.get(assigns.flash, assigns.kind) in @persistent_messages

    assigns =
      assigns
      |> assign(:id, assigns.id || "flash-#{assigns.kind}")
      |> assign(:auto_dismiss, assigns.auto_dismiss and not persistent?)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_dismiss && "AutoDismissFlash"}
      role="alert"
      class={[
        "fixed top-2 left-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1",
        @kind == :info && "bg-emerald-50 ring-emerald-500 fill-cyan-900",
        @kind == :error && "bg-rose-50 shadow-md ring-rose-500 fill-rose-900"
      ]}
      {@rest}
    >
      <p
        :if={@title}
        class="flex items-center gap-1.5 text-sm font-semibold leading-6"
        style={if @kind == :info, do: "color: rgb(6, 95, 70);", else: "color: rgb(190, 18, 60);"}
      >
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        {@title}
      </p>
      <p
        class="mt-2 text-sm leading-5"
        style={if @kind == :info, do: "color: rgb(6, 95, 70);", else: "color: rgb(190, 18, 60);"}
      >
        {msg}
      </p>
      <button
        type="button"
        class="group absolute top-1 right-1 p-2 border border-zinc-300 rounded"
        aria-label={gettext("close")}
      >
        <.icon
          name="hero-x-mark-solid"
          class="h-5 w-5 opacity-40 text-zinc-500 group-hover:opacity-70"
        />
      </button>
      <div
        :if={@auto_dismiss}
        class="progress-bar"
        style={
          "width: 100%; height: 4px; position: absolute; left: 0; right: 0; bottom: 0; background-color: " <>
            if(@kind == :info, do: "rgba(0, 255, 0, 0.5)", else: "rgba(255, 0, 0, 0.5)")
        }
      >
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} title="Success" flash={@flash} />
    <.flash kind={:error} title="Error" flash={@flash} />
    <.flash
      id="client-error"
      kind={:error}
      title="We can't find the internet"
      phx-disconnected={show(".phx-client-error #client-error")}
      phx-connected={hide("#client-error")}
      auto_dismiss={false}
      hidden
    >
      Attempting to reconnect <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
    </.flash>

    <.flash
      id="server-error"
      kind={:error}
      title="Something went wrong"
      phx-disconnected={show(".phx-server-error #server-error")}
      phx-connected={hide("#server-error")}
      auto_dismiss={false}
      hidden
    >
      Hang in there while we get back on track
      <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
    </.flash>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"
  attr :background_color, :string, default: "071f31", doc: "the background color of the form"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div style={"background: ##{@background_color};"}>
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a Cloudflare Turnstile widget inside a form.

  The widget injects a hidden `cf-turnstile-response` input into the form;
  handlers verify it with `Website45sV3.Turnstile.verify/2`. Renders nothing
  when no site key is configured (test env). The `Turnstile` JS hook renders
  the widget explicitly and listens for the `turnstile:reset` event so a
  failed submit gets a fresh token (tokens are single-use).

  ## Examples

      <.turnstile id="registration-turnstile" />
  """
  attr :id, :string, required: true

  def turnstile(assigns) do
    assigns = assign(assigns, :site_key, Website45sV3.Turnstile.site_key())

    ~H"""
    <div
      :if={@site_key}
      id={@id}
      phx-hook="Turnstile"
      phx-update="ignore"
      class="cf-turnstile"
      data-sitekey={@site_key}
      data-action="turnstile-spin-v2"
      style="margin-top: 8px;"
    >
    </div>
    """
  end

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 rounded-lg bg-zinc-900 px-3",
        "text-sm font-semibold leading-6 text-white active:text-white/80",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :background_color, :string, default: "041624", doc: "the background color of the input"
  attr :text_color, :string, default: "d2e8f9", doc: "the text color of the input"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox", value: value} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn -> Form.normalize_value("checkbox", value) end)

    ~H"""
    <div class="mt-4">
      <label
        class="flex items-center text-sm gap-1.5"
        style={"color: ##{@text_color}; margin-bottom: 0;"}
      >
        <input type="hidden" name={@name} value="false" />

        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="mb-0 h-4 w-4 rounded border-zinc-300 text-zinc-900 focus:ring-0"
          style="color: #5e905a"
          {@rest}
        />

        <span class="relative -top-px">
          {@label}
        </span>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class="mt-2 block w-full rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0 sm:text-sm"
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6 min-h-[6rem]",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
      ><%= Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div style={"background-color: ##{@background_color}; color: ##{@text_color};"}>
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={[
          "mt-2 block w-full rounded-md text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        style="background-color: #041624; color: #d2e8f9;"
        {@rest}
      />
      <div style="margin-top: -20px;">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label
      for={@for}
      class="block text-sm font-semibold leading-6"
      style="color: #d2e8f9; margin-bottom: -8px;"
    >
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="flex text-sm leading-6 text-rose-600">
      <.icon name="hero-exclamation-circle-mini" class="h-5 w-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header
      class={[@actions != [] && "flex items-center justify-between gap-6", @class]}
      style="background-color: #041624; border: #041624 solid 2px; margin-bottom: 1rem;"
    >
      <div style="background-color: #071f31; padding-bottom:5px; border: 2px solid #d2e8f9; border-radius: 10px;">
        <h1 class="font-semibold leading-8 mt-3" style="color: #d2e8f9; font-size: 2rem; ">
          {render_slot(@inner_block)}
        </h1>
        <p
          :if={@subtitle != []}
          class="text-xl leading-6"
          style="color: #d2e8f9; margin-top: -1.5rem; margin-bottom: 0.6rem;"
        >
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none" style="background-color: #041624">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from your `assets/vendor/heroicons` directory and bundled
  within your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(Website45sV3Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Website45sV3Web.Gettext, "errors", msg, opts)
    end
  end
end
