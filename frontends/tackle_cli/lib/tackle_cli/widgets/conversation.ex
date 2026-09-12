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
  alias Tackle.CLI.TUI.{MessageView, Theme}
  alias Tackle.CLI.Widgets.Surface

  defmodule Cell do
    @moduledoc false
    @type t :: %__MODULE__{state: reference(), style: ExRatatui.Style.t()}
    defstruct [:state, style: %ExRatatui.Style{}]
  end

  defstruct [:state, scroll_offset: 0, selected: []]

  @type t :: %__MODULE__{
          state: reference(),
          scroll_offset: non_neg_integer(),
          selected: [non_neg_integer()]
        }

  @doc false
  @spec cell(MessageView.t(), pos_integer()) :: [{Cell.t(), non_neg_integer()}]
  def cell(%MessageView{kind: kind} = entry, width) when kind in [:assistant, :user] do
    base =
      if kind == :user,
        do: Theme.merge(Theme.style(:user_surface), entry.style),
        else: entry.style

    marker = if kind == :user, do: "›", else: "●"

    {resource, height} =
      Native.conversation_message(
        entry.content,
        width,
        kind == :assistant,
        style(base),
        {marker, style(Theme.style(:accent_soft))}
      )

    [{%Cell{state: resource, style: base}, height}]
  end

  def cell(%MessageView{} = entry, width) do
    entry |> MessageView.render_entry(width) |> Enum.map(&paragraph_cell(&1, width))
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

  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = widget, %Rect{} = rect) do
    {:ok, rows} =
      Native.conversation_render(
        widget.state,
        rect.width,
        rect.height,
        widget.scroll_offset,
        widget.selected,
        style(Theme.style(:selection_surface))
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
