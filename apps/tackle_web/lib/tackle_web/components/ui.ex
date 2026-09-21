defmodule Tackle.Web.Components.UI do
  @moduledoc """
  The interface's design system: the primitives every screen is built from.

  There is one accent, and it is pink. `primary` marks what is interactive,
  selected, or new; greys carry everything else — the page is `base-100`
  (white), sunken panels are `base-200`, hairlines are `base-300`, and text is
  `base-content` in three weights. Red is reserved for failures, so a failed
  turn never reads as one more accent.

  Every component takes `class` and global attributes, so a screen can adjust
  spacing or sizing without a new variant here. Shape, focus, and the accent
  live in `assets/css/app.css` and the theme in the same file.

  The domain components (`Tackle.Web.Components.Chat` and
  `Tackle.Web.Components.Diff`) are built from these; they should not invent
  their own colours or controls.
  """

  use Phoenix.Component

  import Tackle.Web.CoreComponents, only: [translate_error: 1]

  ## Actions

  @doc """
  A button, or a link styled as one when `href`, `navigate` or `patch` is given.

  Variants:

    * `primary` — the one action a screen is asking for (send, ask, comment)
    * `ghost` — an alternative action of the same weight, outlined
    * `quiet` — a way out (cancel, stop, retry) that should not attract the eye
    * `danger` — destructive, such as deleting a conversation

  ## Examples

      <.button phx-click="send">Send</.button>
      <.button variant="quiet" size="xs" phx-click="cancel_turn">Stop</.button>
      <.button navigate={~p"/projects"} variant="ghost">Back to projects</.button>
  """
  attr(:variant, :string, values: ~w(primary ghost quiet danger), default: "primary")
  attr(:size, :string, values: ~w(xs sm md), default: "sm")
  attr(:class, :any, default: nil)

  attr(:rest, :global,
    include: ~w(href navigate patch method download name value disabled type title)
  )

  slot(:inner_block, required: true)

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [
        button_base(),
        button_size(assigns.size),
        button_variant(assigns.variant),
        assigns.class
      ])

    # A button that navigates is an anchor, and an anchor has no `type`.
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      assigns = assign(assigns, :rest, Map.put_new(rest, :type, "button"))

      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  A square button for an icon, with its label in `title` for the tooltip.

  ## Examples

      <.icon_button phx-click="delete" phx-value-id={id} title="Delete this conversation">
        <.icon name="hero-trash-mini" class="size-3.5" />
      </.icon_button>
  """
  attr(:variant, :string, values: ~w(quiet danger), default: "quiet")
  attr(:size, :string, values: ~w(xs sm md), default: "sm")
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ~w(disabled type title name value))
  slot(:inner_block, required: true)

  def icon_button(assigns) do
    assigns =
      assigns
      |> assign(:class, [
        button_base(),
        icon_button_size(assigns.size),
        button_variant(assigns.variant),
        assigns.class
      ])
      |> assign(:rest, Map.put_new(assigns.rest, :type, "button"))

    ~H"""
    <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  ## Status and surfaces

  @doc """
  A short status label: a file's change, a pull request's state, a draft.

  `added` is pink, because pink is how this interface marks something new. The
  other tones are grey, and their labels say what they are.

  ## Examples

      <.badge tone="added">added</.badge>
      <.badge tone="removed">removed</.badge>
      <.badge>draft</.badge>
  """
  attr(:tone, :string, values: ~w(neutral brand added removed renamed muted), default: "neutral")
  attr(:size, :string, values: ~w(xs sm), default: "xs")
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex flex-none items-center rounded-md font-medium leading-none ring-1 ring-inset",
      @size == "xs" && "px-1.5 py-0.5 text-[0.6875rem]",
      @size == "sm" && "px-2 py-1 text-xs",
      badge_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A message about the state of the screen, not about its content.

  `brand` for something the reader should know or can do, `neutral` for an
  aside, `error` for a failure. The optional `:actions` slot holds the way out
  of it, such as a retry.

  ## Examples

      <.alert tone="error" title="That turn failed">
        The provider rejected the request.
        <:actions><.button variant="quiet" size="xs" phx-click="retry">Retry</.button></:actions>
      </.alert>
  """
  attr(:tone, :string, values: ~w(brand neutral error), default: "neutral")
  attr(:title, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:actions)
  slot(:inner_block, required: true)

  def alert(assigns) do
    ~H"""
    <div
      role={if @tone == "error", do: "alert", else: "status"}
      class={[
        "flex items-start gap-3 rounded-xl border px-3.5 py-3 text-xs leading-relaxed",
        alert_tone(@tone),
        @class
      ]}
      {@rest}
    >
      <span class="mt-1.5 size-1.5 flex-none rounded-full bg-current" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold">{@title}</p>
        <p class={["whitespace-pre-wrap", @title && "mt-0.5 opacity-90"]}>
          {render_slot(@inner_block)}
        </p>
        <div :if={@actions != []} class="mt-2 flex flex-wrap gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A white panel with a hairline border: the container for a form or a header
  block that should read as one object.

  ## Examples

      <.card class="mx-auto max-w-xl">
        <.section_title>Start a chat</.section_title>
        <.form>...</.form>
      </.card>
  """
  attr(:padding, :string, values: ~w(md lg), default: "md")
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <section
      class={[
        "rounded-2xl border border-base-300 bg-base-100",
        @padding == "md" && "p-4",
        @padding == "lg" && "p-6",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A small uppercase label above a group of things, such as a form's fields or a
  sidebar's summary.
  """
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def section_title(assigns) do
    ~H"""
    <h2 class={[
      "text-[0.6875rem] font-semibold uppercase tracking-wider text-base-content/45",
      @class
    ]}>
      {render_slot(@inner_block)}
    </h2>
    """
  end

  ## Data

  @doc """
  How many lines a change adds and removes.

  Additions are pink and removals are grey, matching how the diff itself marks
  them.
  """
  attr(:additions, :integer, required: true)
  attr(:deletions, :integer, required: true)
  attr(:class, :any, default: nil)

  def diff_stats(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 font-mono text-xs", @class]}>
      <span class="text-primary">+{@additions}</span>
      <span class="text-base-content/45">-{@deletions}</span>
    </span>
    """
  end

  @doc """
  A progress bar, used for how much of a review has been read.

  ## Examples

      <.progress value={3} max={8} />
  """
  attr(:value, :integer, required: true)
  attr(:max, :integer, required: true)
  attr(:class, :any, default: nil)

  def progress(assigns) do
    ~H"""
    <div
      role="progressbar"
      aria-valuenow={@value}
      aria-valuemin="0"
      aria-valuemax={@max}
      class={["h-1 w-full overflow-hidden rounded-full bg-base-300", @class]}
    >
      <div
        class="h-full rounded-full bg-primary transition-[width]"
        style={progress_style(@value, @max)}
      />
    </div>
    """
  end

  @doc """
  An animated ring, for a place where something is loading.

  The ring is pink when it spins, so a loading screen still looks like this
  interface.
  """
  attr(:size, :string, values: ~w(xs sm md), default: "sm")
  attr(:class, :any, default: nil)

  def spinner(assigns) do
    ~H"""
    <span
      role="status"
      aria-label="Loading"
      class={[
        "inline-block flex-none animate-spin rounded-full border-2 border-base-300 border-t-primary",
        @size == "xs" && "size-3.5",
        @size == "sm" && "size-4",
        @size == "md" && "size-6",
        @class
      ]}
    />
    """
  end

  @doc """
  A centered explanation of why there is nothing to show, with the way out.

  `icon` is a heroicon name; `:actions` holds what the reader can do about it.

  ## Examples

      <.empty_state icon="hero-document-magnifying-glass" title="No changes">
        These refs point at the same tree.
      </.empty_state>
  """
  attr(:icon, :string, default: nil)
  attr(:title, :string, default: nil)
  attr(:class, :any, default: nil)
  slot(:actions)
  slot(:inner_block, required: true)

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center gap-3 px-6 py-12 text-center", @class]}>
      <span
        :if={@icon}
        class="grid size-10 flex-none place-items-center rounded-full bg-accent text-accent-content"
      >
        <span class={[@icon, "size-5"]} />
      </span>
      <div class="max-w-md">
        <p :if={@title} class="text-sm font-medium">{@title}</p>
        <p class="mt-1 text-xs leading-relaxed text-base-content/60">{render_slot(@inner_block)}</p>
      </div>
      <div :if={@actions != []} class="mt-1 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  ## Layout

  @doc """
  A link in the app's top navigation, marking itself when it is the open
  section with a pink underline.
  """
  attr(:navigate, :string, required: true)
  attr(:active, :boolean, default: false)
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "-mb-px inline-flex items-center border-b-2 px-2.5 py-3.5 text-sm transition-colors",
        @active && "border-primary font-medium text-primary",
        !@active && "border-transparent text-base-content/55 hover:text-base-content",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  A link that is not a button and not navigation: something to read next, such
  as a pull request's page on GitHub.
  """
  attr(:href, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ~w(target rel))
  slot(:inner_block, required: true)

  def external_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noreferrer"
      class={["text-primary underline-offset-2 hover:underline", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  ## Forms

  @doc """
  A labelled control, with an optional hint under it.

  The label is a small uppercase caption, and `for` should match the control's
  id so clicking it focuses the control.

  ## Examples

      <.field label="Working directory" for={@form[:workspace].id} hint="Files are read here.">
        <.input field={@form[:workspace]} class="font-mono" />
      </.field>
  """
  attr(:label, :string, default: nil)
  attr(:hint, :string, default: nil)
  attr(:for, :string, default: nil)
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def field(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @class]}>
      <label
        :if={@label}
        for={@for}
        class="text-[0.6875rem] font-medium uppercase tracking-wide text-base-content/45"
      >
        {@label}
      </label>
      {render_slot(@inner_block)}
      <p :if={@hint} class="text-[0.6875rem] leading-relaxed text-base-content/45">{@hint}</p>
    </div>
    """
  end

  @doc """
  One control of a form: a text input, a select, a textarea, or a checkbox.

  A `Phoenix.HTML.FormField` may be passed as `field`, which supplies the name,
  id, value, and errors; otherwise the attributes are passed explicitly. Errors
  are rendered under the control, and only once the field has been used, so a
  form the reader has not touched yet is not shown as invalid.

  ## Examples

      <.input field={@form[:workspace]} class="font-mono" />
      <.input type="select" name="model" options={@models} value={@model} />
      <.input type="textarea" name="comment[body]" rows="3" autofocus />
      <.input type="checkbox" checked={@viewed} phx-click="toggle_viewed" />

  A checkbox posts `"true"` when it is checked and nothing when it is not; it
  is a toggle driven by `phx-click`, not a field of a form.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any, default: nil)
  attr(:value, :any, default: nil)

  attr(:type, :string,
    default: "text",
    values: ~w(text search password number url email select textarea checkbox)
  )

  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
  attr(:checked, :boolean, default: false)
  attr(:prompt, :string, default: nil)
  attr(:options, :list, default: [])
  attr(:size, :string, values: ~w(xs sm md), default: "sm")
  attr(:class, :any, default: nil, doc: "classes for the control itself")
  attr(:wrapper_class, :any, default: nil, doc: "classes for the element around the control")

  attr(:rest, :global,
    include: ~w(accept autocomplete autofocus cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns =
      assigns
      |> assign(field: nil)
      |> assign(:id, assigns.id || field.id)
      |> assign(:name, field.name)
      |> assign(:value, field.value)
      |> assign(:errors, Enum.map(errors, &translate_error(&1)))

    assigns =
      if assigns.type == "checkbox" do
        assign(assigns, :checked, Phoenix.HTML.Form.normalize_value("checkbox", field.value))
      else
        assigns
      end

    input(assigns)
  end

  def input(%{type: "checkbox"} = assigns) do
    ~H"""
    <input
      type="checkbox"
      id={@id}
      name={@name}
      value="true"
      checked={@checked}
      class={[
        "size-3.5 flex-none cursor-pointer rounded border-base-300 accent-primary",
        @class
      ]}
      {@rest}
    />
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @wrapper_class]}>
      <select id={@id} name={@name} class={[control_classes(@size), "pr-7", @class]} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.input_errors errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @wrapper_class]}>
      <textarea
        id={@id}
        name={@name}
        class={[
          control_classes(@size),
          "h-auto min-h-20 resize-y py-2 leading-relaxed",
          @class
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.input_errors errors={@errors} />
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @wrapper_class]}>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[control_classes(@size), @class]}
        {@rest}
      />
      <.input_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  The errors of a field, as text under the control they belong to.
  """
  attr(:errors, :list, default: [])

  def input_errors(assigns) do
    ~H"""
    <p :for={error <- @errors} class="text-[0.6875rem] leading-relaxed text-error">{error}</p>
    """
  end

  ## Classes

  defp button_base do
    "inline-flex items-center justify-center gap-1.5 font-medium whitespace-nowrap " <>
      "cursor-pointer transition-colors select-none disabled:pointer-events-none disabled:opacity-40"
  end

  defp button_size("xs"), do: "h-7 rounded-lg px-2.5 text-xs"
  defp button_size("sm"), do: "h-8 rounded-lg px-3 text-xs"
  defp button_size("md"), do: "h-10 rounded-xl px-4 text-sm"

  defp icon_button_size("xs"), do: "size-7 rounded-lg"
  defp icon_button_size("sm"), do: "size-8 rounded-lg"
  defp icon_button_size("md"), do: "size-10 rounded-xl"

  defp button_variant("primary"), do: "bg-primary text-primary-content hover:bg-primary/90"

  defp button_variant("ghost"),
    do: "border border-base-300 bg-base-100 text-base-content hover:bg-base-200"

  defp button_variant("quiet"),
    do: "text-base-content/60 hover:bg-base-200 hover:text-base-content"

  defp button_variant("danger"), do: "text-base-content/60 hover:bg-error/10 hover:text-error"

  defp badge_tone("neutral"), do: "bg-base-100 text-base-content/70 ring-base-300"
  defp badge_tone("brand"), do: "bg-accent text-accent-content ring-transparent"
  defp badge_tone("added"), do: "bg-accent text-primary ring-transparent"
  defp badge_tone("removed"), do: "bg-base-200 text-base-content/55 ring-base-300"
  defp badge_tone("renamed"), do: "bg-base-100 text-base-content/70 ring-base-300"
  defp badge_tone("muted"), do: "bg-base-300 text-base-content/55 ring-transparent"

  defp alert_tone("brand"), do: "border-primary/20 bg-accent text-accent-content"
  defp alert_tone("neutral"), do: "border-base-300 bg-base-200 text-base-content/70"
  defp alert_tone("error"), do: "border-error/25 bg-error/5 text-error"

  defp control_classes(size) do
    [
      "ui-control w-full border border-base-300 bg-base-100 text-base-content",
      "placeholder:text-base-content/35 disabled:cursor-not-allowed disabled:bg-base-200",
      size_classes(size)
    ]
  end

  defp size_classes("xs"), do: "h-7 rounded-lg px-2 text-xs"
  defp size_classes("sm"), do: "h-8 rounded-lg px-2.5 text-xs"
  defp size_classes("md"), do: "h-10 rounded-xl px-3 text-sm"

  defp progress_style(_value, max) when max <= 0, do: "width: 0%"

  defp progress_style(value, max) do
    "width: #{min(value, max) / max * 100}%"
  end
end
