defmodule Tackle.Web.CoreComponents do
  @moduledoc """
  The helpers every screen shares that are not visual primitives.

  The components the interface is built from live in
  `Tackle.Web.Components.UI`; what is left here is the Phoenix-conventional
  plumbing the rest of the application expects: flashes, icons, the JS show/hide
  commands, error translation, and the table and list the generators emit.

  Both modules are imported for every template by `Tackle.Web`, so a screen can
  use `<.button>`, `<.badge>`, `<.icon>` and the rest without importing
  anything.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash id="welcome-back" kind={:info} hidden>Welcome back!</.flash>
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      data-flash
      role="alert"
      class="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
      {@rest}
    >
      <div class={[
        "pointer-events-auto flex w-full max-w-md items-start gap-3 rounded-xl border bg-base-100 px-4 py-3 text-xs leading-relaxed shadow-lg shadow-base-content/5",
        @kind == :info && "border-primary/25",
        @kind == :error && "border-error/25"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-check-circle-mini"
          class="mt-px size-4 flex-none text-primary"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle-mini"
          class="mt-px size-4 flex-none text-error"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class={[@kind == :error && "text-error", @kind == :info && "text-base-content"]}>
            {msg}
          </p>
        </div>
        <button
          type="button"
          class="-m-1 flex-none cursor-pointer rounded-lg p-1 text-base-content/40 hover:bg-base-200 hover:text-base-content"
          aria-label="Close"
          phx-click={JS.hide(to: "##{@id}")}
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may be
  applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from `deps/heroicons` and bundled within your compiled
  app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "size-4")

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a table with generic styling.
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")
  attr(:row_click, :any, default: nil, doc: "the function for handling phx-click on each row")

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action, doc: "the slot for showing user actions in the last table column")

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full border-collapse text-left text-sm">
      <thead class="border-b border-base-300 text-[0.6875rem] uppercase tracking-wide text-base-content/45">
        <tr>
          <th :for={col <- @col} class="px-3 py-2 font-medium">{col[:label]}</th>
          <th :if={@action != []} class="px-3 py-2">
            <span class="sr-only">Actions</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="border-b border-base-300/60 last:border-0 hover:bg-base-200"
        >
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={["px-3 py-2 align-top", @row_click && "cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 px-3 py-2 align-top">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.
  """
  slot :item, required: true do
    attr(:title, :string, required: true)
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-base-300/60">
      <li :for={item <- @item} class="py-2">
        <p class="text-sm font-medium">{item.title}</p>
        <div class="text-xs text-base-content/60">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  @doc """
  Hides an element with a transition, for a flash or a dismissed panel.
  """
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Shows an element with a transition, the counterpart of `hide/2`.
  """
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(Tackle.Web.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(Tackle.Web.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders the reason an `assign_async/3` load failed.

  A handled failure arrives as `{:error, reason}` and a crash in the loading
  function as `{:exit, reason}`; both reach the `:failed` slot, so both are
  turned into something a reviewer can read.
  """
  # `to_string/1` only works for reasons that implement `String.Chars`; a host
  # reason is any term, so anything else is inspected rather than crashing the
  # very error path that is trying to report it.
  def async_failure_message({:error, reason}) when is_binary(reason), do: reason
  def async_failure_message({:error, reason}), do: "Loading failed: #{inspect(reason)}"
  def async_failure_message({:exit, reason}), do: "Loading failed: #{inspect(reason)}"
  def async_failure_message(other), do: "Loading failed: #{inspect(other)}"
end
