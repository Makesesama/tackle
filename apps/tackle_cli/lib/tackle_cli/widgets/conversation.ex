defmodule Tackle.CLI.Widgets.Conversation do
  @moduledoc """
  Tackle-owned native transcript. Immutable history-cell resources cache parsed
  Markdown and width-dependent measurements; a scene holds a snapshot, not a
  mutable shared viewport. Only painted viewport rows cross back to ExRatatui.

  Elixir projects messages/tool previews and owns source, selection and reading
  anchors. Rust owns Markdown layout, cell placement, clipping and selection
  paint. Resources are local and must not be persisted or sent to another node.
  """

  alias ExRatatui.{Layout.Rect, Style}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{CodeFences, MessageView, Theme}
  alias Tackle.CLI.Widgets.Surface

  defmodule Cell do
    @moduledoc false
    @type t :: %__MODULE__{state: reference(), style: ExRatatui.Style.t()}
    defstruct [:state, style: %ExRatatui.Style{}]
  end

  defstruct [:state, scroll_offset: 0, selected: [], text_selection: nil]

  @type t :: %__MODULE__{
          state: reference(),
          scroll_offset: non_neg_integer(),
          selected: [non_neg_integer()],
          text_selection: tuple() | nil
        }

  @doc false
  @spec cell(MessageView.t(), pos_integer()) :: [{Cell.t(), non_neg_integer()}]
  def cell(%MessageView{kind: :assistant} = entry, width) do
    {items, _cache} = cached_cell(entry, width, %{})
    items
  end

  def cell(%MessageView{kind: :user} = entry, width) do
    base = Theme.merge(Theme.style(:user_surface), entry.style)

    {resource, height} =
      Native.conversation_message(
        entry.content,
        width,
        false,
        style(base),
        {"›", style(Theme.style(:accent_soft))}
      )

    [{%Cell{state: resource, style: base}, height}]
  end

  def cell(%MessageView{} = entry, width) do
    entry |> MessageView.render_entry(width) |> Enum.map(&paragraph_cell(&1, width))
  end

  @doc false
  @spec cached_cell(MessageView.t(), pos_integer(), map()) ::
          {[{Cell.t(), non_neg_integer()}], map()}
  def cached_cell(%MessageView{kind: :assistant} = entry, width, previous) do
    # Rescan the complete source: an appended fence delimiter can change the
    # segmentation. Reuse only identical segments, never arbitrary Markdown
    # paragraphs whose meaning can depend on later reference definitions.
    {items, cache} =
      entry.content
      |> CodeFences.split()
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {segment, index}, cache ->
        key = {segment, index == 0, width, entry.style}

        item =
          case Map.fetch(previous, key) do
            {:ok, item} -> item
            :error -> assistant_cell(segment, index == 0, width, entry.style, "●")
          end

        {item, Map.put(cache, key, item)}
      end)

    # Retain only this snapshot's segments, not every version of the live tail.
    {items, cache}
  end

  def cached_cell(%MessageView{} = entry, width, _previous), do: {cell(entry, width), %{}}

  defp assistant_cell({:markdown, content}, first?, width, base, marker) do
    {resource, height} =
      Native.conversation_message(
        content,
        width,
        true,
        style(base),
        {if(first?, do: marker, else: ""), style(Theme.style(:accent_soft))}
      )

    {%Cell{state: resource, style: base}, height}
  end

  defp assistant_cell({:code, language, code}, first?, width, base, marker) do
    # The highlighter supplies token colours and its own lighter background.
    # Keep the colours but paint a single darker band across every code row.
    surface = Theme.merge(base, Theme.style(:code_surface))

    rows =
      code
      |> ExRatatui.CodeBlock.highlight(language, :base16_ocean_dark)
      |> Enum.map(fn %Line{spans: spans, style: row_style} ->
        {Enum.map(spans, fn %Span{content: content, style: span_style} ->
           {String.trim_trailing(content, "\n"), style(%{span_style | bg: nil})}
         end), style(%{row_style | bg: nil})}
      end)

    # The last newline of a fenced block is structural, not an extra code row.
    rows = if rows == [], do: [{[], style(%Style{})}], else: rows
    marker = if first?, do: {marker, style(Theme.style(:accent_soft))}, else: nil
    {resource, height} = Native.conversation_code(rows, width, style(surface), marker, language)
    {%Cell{state: resource, style: surface}, height}
  end

  @doc false
  @spec spacer(pos_integer()) :: {Cell.t(), pos_integer()}
  def spacer(width), do: paragraph_cell({%Paragraph{text: ""}, 1}, width)

  defp paragraph_cell({%Paragraph{text: text, style: base}, _height}, width) do
    lines =
      if is_binary(text),
        do: Enum.map(String.split(text, "\n"), &Line.new([Span.new(&1)])),
        else: text

    rows =
      Enum.map(lines, fn %Line{spans: spans, style: row_style} ->
        {Enum.map(spans, fn %Span{content: content, style: span_style} ->
           {content, style(span_style)}
         end), style(Theme.merge(base, row_style))}
      end)

    {resource, height} = Native.conversation_rows(rows, width)
    {%Cell{state: resource, style: base}, height}
  end

  @doc false
  @spec assemble([{Cell.t(), non_neg_integer()}], pos_integer()) ::
          {reference(), non_neg_integer()}
  def assemble(items, width) do
    Native.conversation_new(Enum.map(items, fn {%Cell{state: state}, _} -> state end), width)
  end

  @doc false
  def assemble_sections(sections, width) do
    Native.conversation_sections(Enum.map(sections, &cell_states/1), width)
  end

  @doc false
  def replace_section(state, index, items) do
    Native.conversation_replace(state, index, cell_states(items))
  end

  defp cell_states(items), do: Enum.map(items, fn {%Cell{state: state}, _} -> state end)

  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = widget, %Rect{} = rect) do
    {:ok, rows} =
      Native.conversation_render(
        widget.state,
        rect.width,
        rect.height,
        widget.scroll_offset,
        widget.selected,
        style(Theme.style(:selection_surface)),
        widget.text_selection
      )

    Surface.place(rows, rect)
  end

  @doc false
  def style(%Style{} = style) do
    bits = %{bold: 1, dim: 2, italic: 4, underlined: 8, reversed: 64, crossed_out: 256}
    modifiers = Enum.reduce(style.modifiers, 0, &Bitwise.bor(Map.fetch!(bits, &1), &2))
    {color(style.fg), color(style.bg), color(style.underline_color), modifiers}
  end

  defp color(nil), do: nil
  defp color(:reset), do: nil
  defp color({:indexed, index}), do: index
  defp color({:rgb, r, g, b}), do: {r, g, b}

  defp color(name) do
    Enum.find_index(
      [
        :black,
        :red,
        :green,
        :yellow,
        :blue,
        :magenta,
        :cyan,
        :gray,
        :dark_gray,
        :light_red,
        :light_green,
        :light_yellow,
        :light_blue,
        :light_magenta,
        :light_cyan,
        :white
      ],
      &(&1 == name)
    ) || raise ArgumentError, "unsupported color: #{inspect(name)}"
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.Conversation
  end
end
