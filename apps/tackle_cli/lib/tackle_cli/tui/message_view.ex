defmodule Tackle.CLI.TUI.MessageView do
  @moduledoc """
  Converts conversation state into typed entries and native ExRatatui widgets.

  Every entry keeps its complete retained source separately from the bounded
  widget preview painted on screen. Paint is a security boundary: `render_entry/2`
  strips ANSI/OSC controls and other non-display bytes before text reaches a
  widget. Copy and inspector actions use the raw retained source instead, so a
  truncated or sanitized preview never destroys data the user explicitly asks
  for.

  Transcript rows are rich-text `%ExRatatui.Text.Line{}` values whose style
  carries a semantic surface. `render_rows/2` wraps spans to the available
  width, groups consecutive equal-style rows, and emits one `%Paragraph{}` per
  group. A `Paragraph` paints its style background across its whole rect, so a
  group becomes a full-width band even when its text is short.

  Assistant content is retained here and handed to the native conversation
  widget for measured Markdown layout. Tool entries keep a bounded head/tail
  preview inline and the complete result available through the output inspector.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.TUI.{Compaction, Theme, ToolView}
  alias Tackle.Lib.JSON
  alias Tackle.Lib.Message
  @conversation_chunk_rows 64
  @zero_width_grapheme ~r/^[\p{M}\p{Cf}]+$/u
  @emoji_presentation ~r/\p{Emoji_Presentation}/u
  @wide_codepoint_ranges [
    {0x1100, 0x115F},
    {0x231A, 0x231B},
    {0x2329, 0x232A},
    {0x2E80, 0xA4CF},
    {0xAC00, 0xD7A3},
    {0xF900, 0xFAFF},
    {0xFE10, 0xFE19},
    {0xFE30, 0xFE6F},
    {0xFF00, 0xFF60},
    {0xFFE0, 0xFFE6},
    {0x1F1E6, 0x1FAFF},
    {0x20000, 0x3FFFD}
  ]

  @typedoc "A terminal conversation entry before it is projected into widgets."
  @type kind :: :user | :assistant | :thinking | :tool | :compaction | :error | :welcome
  @type t :: %__MODULE__{
          kind: kind(),
          content: String.t(),
          label: String.t() | nil,
          style: Style.t(),
          id: String.t() | nil,
          source: String.t() | nil,
          tool_output: String.t() | nil,
          tool_name: String.t() | nil,
          tool_arguments: term(),
          model: String.t() | nil,
          tool_status: atom() | nil,
          tool_elapsed_ms: non_neg_integer() | nil,
          subagent_work: String.t() | nil,
          subagent_output: String.t() | nil,
          collapsed?: boolean()
        }

  @enforce_keys [:kind, :content]
  defstruct [
    :kind,
    :content,
    :label,
    :id,
    :source,
    :tool_output,
    :tool_name,
    :tool_arguments,
    :model,
    :tool_status,
    :tool_elapsed_ms,
    :subagent_work,
    :subagent_output,
    style: %Style{},
    collapsed?: false
  ]

  @typedoc "A styled transcript row before wrapping."
  @type row :: Line.t()

  @typedoc "A primitive widget and its exact row height in the conversation list."
  @type widget_item :: {struct(), non_neg_integer()}

  @doc "Returns the typed entries for one conversation section."
  @spec section_entries(map(), atom()) :: [t()]
  def section_entries(state, :settled) do
    messages = state.agent_state.messages || []

    results =
      Map.new(
        for %Message{role: :tool, tool_call_id: id} = message <- messages,
            is_binary(id),
            do: {id, message}
      )

    call_ids =
      messages
      |> Enum.flat_map(fn message -> message.tool_calls || [] end)
      |> Enum.map(&value(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    cards = Enum.filter(Map.get(state, :compactions, []), &is_nil(&1.turn_id))

    groups =
      messages
      |> Enum.with_index()
      |> Enum.map(fn
        {%Message{role: :tool, tool_call_id: id} = message, index} ->
          if MapSet.member?(call_ids, id), do: [], else: message_entries(message, index, state)

        {%Message{role: :assistant} = message, index} ->
          prose = message_entries(%{message | tool_calls: []}, index, state)

          calls =
            (message.tool_calls || [])
            |> Enum.with_index()
            |> Enum.map(fn {call, call_index} ->
              build_call_entry(call, call_index, results, index)
            end)

          prose ++ calls

        {message, index} ->
          message_entries(message, index, state)
      end)

    Enum.flat_map(Enum.with_index(groups), fn {entries, index} ->
      Enum.map(Enum.filter(cards, &(&1.boundary == index)), &compaction_entry/1) ++ entries
    end) ++ Enum.map(Enum.filter(cards, &(&1.boundary >= length(messages))), &compaction_entry/1)
  end

  def section_entries(state, :pending) do
    if is_binary(state.pending_prompt) do
      [
        entry(:user, state.pending_prompt,
          id: "pending",
          label: "You:",
          source: state.pending_prompt,
          style: style(:user)
        )
      ]
    else
      []
    end
  end

  def section_entries(state, :turn) do
    state.stream.timeline
    |> Enum.with_index()
    |> Enum.map(fn
      {%{kind: :thinking, content: content} = item, index} ->
        entry(:thinking, content,
          id: Map.get(item, :id, live_text_id(:thinking, index)),
          label: "Thinking:",
          source: content,
          collapsed?: not state.thinking_expanded?,
          style: style(:thinking)
        )

      {%{kind: :assistant, content: content} = item, index} ->
        entry(:assistant, content,
          id: Map.get(item, :id, live_text_id(:assistant, index)),
          label: "Tackle:",
          source: content,
          style: style(:assistant)
        )

      {%{kind: :compaction, id: id}, _index} ->
        state.compactions |> Enum.find(&(&1.id == id)) |> compaction_entry()

      {%{kind: :tool} = item, _index} ->
        tool_entry(item, Map.get(item, :timeline_id, "tool:#{tool_id(item)}"))
    end)
  end

  # Kept as a small compatibility seam for callers that render a standalone
  # collection of live tools. The conversation itself uses the ordered :turn
  # section above.
  def section_entries(state, :tools) do
    Enum.map(state.tool_activity, &tool_entry(&1, "tool:#{tool_id(&1)}"))
  end

  def section_entries(state, :thinking) do
    if state.stream.thinking == "" do
      []
    else
      [
        entry(:thinking, state.stream.thinking,
          id: "streaming:thinking",
          label: "Thinking:",
          source: state.stream.thinking,
          collapsed?: not state.thinking_expanded?,
          style: style(:thinking)
        )
      ]
    end
  end

  def section_entries(state, :response) do
    if state.stream.response == "" do
      []
    else
      [
        entry(:assistant, state.stream.response,
          id: "streaming:response",
          label: "Tackle:",
          source: state.stream.response,
          style: style(:assistant)
        )
      ]
    end
  end

  def section_entries(state, :error) do
    if state.error do
      [
        entry(:error, state.error,
          id: "turn:error",
          label: "Error:",
          source: state.error,
          style: style(:error)
        )
      ]
    else
      []
    end
  end

  defp compaction_entry(data) do
    text =
      if Map.get(data, :restored?),
        do: "Restored context checkpoint (historical position unavailable)",
        else: Compaction.card_text(data)

    summary = Map.get(data, :summary)
    source = if summary, do: text <> "\n\n" <> summary, else: text

    entry(:compaction, text,
      id: data.id,
      label: "Compaction:",
      source: source,
      collapsed?: is_binary(summary),
      style: if(data.status == :failed, do: Theme.style(:error), else: Theme.style(:accent_soft))
    )
  end

  defp live_text_id(:thinking, 0), do: "streaming:thinking"
  defp live_text_id(:assistant, 0), do: "streaming:response"
  defp live_text_id(kind, index), do: "streaming:#{kind}:#{index}"

  defp build_call_entry(call, call_index, results, index) do
    id = value(call, :id)
    result = Map.get(results, id)

    tool_entry(
      %{
        name: value(call, :name),
        arguments: value(call, :arguments),
        status: result_status(result),
        result: if(result, do: result.content)
      },
      if(is_binary(id), do: "tool:#{id}", else: "message:#{index}:call:#{call_index}")
    )
  end

  @doc "Builds a typed welcome entry used when a session has no messages yet."
  @spec welcome_entry(String.t() | nil) :: t()
  def welcome_entry(model \\ nil) do
    model_text = if is_binary(model), do: " Model: #{model}.", else: ""

    entry(
      :welcome,
      "Welcome to Tackle.#{model_text} Type a prompt below to start a session.",
      id: "welcome",
      style: style(:welcome)
    )
  end

  @doc "Returns the unwrapped retained source for a copy or search operation."
  @spec source(t()) :: String.t()
  def source(%__MODULE__{source: source}) when is_binary(source), do: source
  def source(%__MODULE__{content: content}), do: content

  @doc "Returns the full source with its role label, suitable for message copy."
  @spec source_text(t()) :: String.t()
  def source_text(%__MODULE__{label: nil} = entry), do: source(entry)
  def source_text(%__MODULE__{label: label} = entry), do: label <> "\n" <> source(entry)

  @doc "Returns the display text represented by an entry without paint sanitizing it."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{label: nil, content: content}), do: content
  def text(%__MODULE__{label: label, content: content}), do: label <> "\n" <> content

  @doc "Returns the retained full tool result or error, if this is a tool entry."
  @spec tool_output(t()) :: String.t() | nil
  def tool_output(%__MODULE__{kind: :tool, tool_output: output}), do: output
  def tool_output(_entry), do: nil

  @doc """
  Returns the complete retained text used by the output inspector and copy.

  Tool entries expose their raw result without command chrome; other entries
  expose their labeled message source.
  """
  @spec full_text(t()) :: String.t()
  def full_text(%__MODULE__{kind: :tool, tool_output: output}) when is_binary(output), do: output

  def full_text(%__MODULE__{kind: :tool, subagent_output: output}) when is_binary(output),
    do: output

  def full_text(%__MODULE__{kind: :tool} = entry), do: source_text(entry)
  def full_text(%__MODULE__{} = entry), do: source_text(entry)

  @doc "Returns source text used by transcript search, excluding paint-only chrome."
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{kind: :tool} = entry) do
    entry.content <>
      "\n" <>
      format_value(entry.tool_arguments || %{}) <>
      "\n" <> (tool_output(entry) || entry.subagent_output || "")
  end

  def search_text(%__MODULE__{} = entry), do: source(entry)

  @doc """
  Builds a styled span, stripping terminal controls at the paint boundary.

  Span content cannot contain newlines; callers split multi-line source into
  rows first. Any newline that still reaches this function is flattened to a
  space so untrusted tool text cannot raise or inject layout.
  """
  @spec span(String.t(), Style.t()) :: Span.t()
  def span(text, style \\ %Style{}) when is_binary(text) do
    Span.new(text |> sanitize() |> String.replace("\n", " "), style: style)
  end

  @doc "Returns the terminal cell width of `text`, counting wide and zero-width graphemes."
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, total -> total + terminal_width(grapheme) end)
  end

  @doc "Builds one styled transcript row from a string or a list of spans."
  @spec row(String.t() | [Span.t()], Style.t()) :: row()
  def row(text, style \\ %Style{})
  def row(text, style) when is_binary(text), do: Line.new([span(text)], style: style)
  def row(spans, style) when is_list(spans), do: Line.new(spans, style: style)

  @doc """
  Wraps rows to `width` display cells, preserving span styles and each row's
  surface style on every wrapped continuation.
  """
  @spec wrap_rows([row()], pos_integer()) :: [row()]
  def wrap_rows(rows, width) do
    width = max(width, 1)
    Enum.flat_map(rows, &wrap_row(&1, width))
  end

  @doc """
  Groups consecutive equal-style rows into `%Paragraph{}` bands.

  Because a paragraph fills its whole rect with its style background, each
  group paints a full-width band; the group height is its wrapped row count.
  """
  @spec render_lines([row()]) :: [widget_item()]
  def render_lines(lines) do
    lines
    |> Enum.chunk_by(& &1.style)
    |> Enum.map(fn group ->
      {%Paragraph{text: group, style: hd(group).style}, length(group)}
    end)
  end

  @doc "Wraps and renders rows into primitive widgets."
  @spec render_rows([row()], pos_integer()) :: [widget_item()]
  def render_rows(rows, width), do: rows |> wrap_rows(width) |> render_lines()

  @doc "Builds widgets for a typed entry while preserving full source separately."
  @spec render_entry(t(), pos_integer()) :: [widget_item()]
  def render_entry(%__MODULE__{kind: :thinking, collapsed?: true} = entry, width) do
    render_rows(thinking_rows(entry, :collapsed), width)
  end

  def render_entry(%__MODULE__{kind: :thinking} = entry, width) do
    render_rows(thinking_rows(entry, :expanded), width)
  end

  def render_entry(%__MODULE__{kind: :compaction} = entry, width) do
    hint = if entry.collapsed?, do: " · F4 browse, Enter summary", else: ""
    render_rows([row([span("◦ " <> entry.content <> hint, entry.style)], %Style{})], width)
  end

  def render_entry(%__MODULE__{kind: :tool} = entry, width),
    do: ToolView.render(entry, width)

  def render_entry(%__MODULE__{kind: :user} = entry, width),
    do: render_rows(user_rows(entry), width)

  def render_entry(%__MODULE__{kind: :error} = entry, width),
    do: render_rows(error_rows(entry), width)

  def render_entry(%__MODULE__{} = entry, width) do
    entry.content
    |> sanitize()
    |> String.split("\n", trim: false)
    |> Enum.map(&row([span(&1, Theme.style(:muted))], %Style{}))
    |> render_rows(width)
  end

  @doc """
  Layers a background over every widget of an entry.

  Each rendered widget already paints a full-width band from its own style, so
  the selection surface is merged *over* that style: backgrounds the entry set
  (tool cards, user messages) give way to the selection, while every foreground
  and modifier the entry chose is preserved.
  """
  @spec highlight([widget_item()], Style.t()) :: [widget_item()]
  def highlight(items, %Style{} = style) do
    Enum.map(items, fn {widget, height} -> {merge_style(widget, style), height} end)
  end

  defp merge_style(%{style: widget_style} = widget, style) when is_struct(widget_style) do
    %{widget | style: Theme.merge(widget_style, style)}
  end

  defp merge_style(widget, _style), do: widget

  @doc "Builds widgets for the full retained text of an entry (output inspector)."
  @spec inspect_items(t(), pos_integer()) :: [widget_item()]
  def inspect_items(%__MODULE__{kind: :tool} = entry, width),
    do: ToolView.render(entry, width, :details)

  def inspect_items(%__MODULE__{} = entry, width) do
    render_text(full_text(entry), width, Theme.style(:muted))
  end

  @doc "Wraps and chunks arbitrary text into primitive widgets."
  @spec render_text(String.t(), pos_integer(), Style.t()) :: [widget_item()]
  def render_text(text, width, style \\ %Style{}) do
    text
    |> sanitize()
    |> wrap_text(max(width, 1))
    |> String.split("\n", trim: false)
    |> Enum.chunk_every(@conversation_chunk_rows)
    |> Enum.map(fn lines ->
      {%Paragraph{text: Enum.join(lines, "\n"), style: style}, length(lines)}
    end)
  end

  @doc "Strips terminal control sequences before any model/tool text reaches paint."
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> sanitize_chars(:normal, [])
    |> Enum.reverse()
    |> List.to_string()
  end

  @doc false
  @spec style(kind()) :: Style.t()
  def style(:user), do: Theme.style(:text)
  def style(:assistant), do: Theme.style(:text)
  def style(:thinking), do: Theme.style(:muted)
  def style(:tool), do: Theme.style(:muted)
  def style(:compaction), do: Theme.style(:accent_soft)
  def style(:error), do: Theme.style(:error)
  def style(:welcome), do: Theme.style(:muted)

  defp user_rows(entry) do
    surface = Theme.style(:user_surface)
    text = Theme.merge(surface, Theme.style(:text))
    accent = Theme.style(:accent)

    entry.content
    |> sanitize()
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      prefix = if index == 0, do: "› ", else: "  "
      row([span(prefix, accent), span(line, text)], surface)
    end)
  end

  defp thinking_rows(entry, mode) do
    source = sanitize(source(entry))
    lines = String.split(source, "\n", trim: false)
    muted = Theme.style(:muted)

    hint =
      if mode == :collapsed, do: [span("  ·  Ctrl+T to reveal", Theme.style(:subtle))], else: []

    header =
      row(
        [
          span(if(mode == :collapsed, do: "› ", else: "⌄ "), muted),
          span("thought", muted),
          span("  ·  #{length(lines)} lines", muted)
        ] ++ hint,
        %Style{}
      )

    case mode do
      :collapsed ->
        [header | collapsed_thinking_rows(lines, muted)]

      :expanded ->
        [header | Enum.map(lines, &row([span("  " <> &1, Theme.italic(muted))], %Style{}))]
    end
  end

  defp collapsed_thinking_rows(lines, muted) do
    Enum.map(lines, fn line ->
      preview = truncate_line(line, 180)
      row([span("  ", %Style{}), span(preview, Theme.italic(muted))], %Style{})
    end)
  end

  defp error_rows(entry) do
    surface = Theme.style(:error_surface)
    text = Theme.merge(surface, %Style{fg: :white})
    marker = Theme.style(:error)

    entry.content
    |> sanitize()
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      prefix = if index == 0, do: "✗ ", else: "  "
      row([span(prefix, marker), span(line, text)], surface)
    end)
  end

  defp message_entries(%Message{role: :user, content: content}, index, _state)
       when is_binary(content) do
    [
      entry(:user, content,
        id: "message:#{index}:user",
        label: "You:",
        source: content,
        style: style(:user)
      )
    ]
  end

  defp message_entries(%Message{role: :assistant} = message, index, state) do
    thinking =
      if is_binary(message.thinking) and message.thinking != "" do
        [
          entry(:thinking, message.thinking,
            id: "message:#{index}:thinking",
            label: "Thinking:",
            source: message.thinking,
            collapsed?: not state.thinking_expanded?,
            style: style(:thinking)
          )
        ]
      else
        []
      end

    content =
      if is_binary(message.content) and message.content != "" do
        [
          entry(:assistant, message.content,
            id: "message:#{index}:assistant",
            label: "Tackle:",
            source: message.content,
            style: style(:assistant)
          )
        ]
      else
        []
      end

    thinking ++ content
  end

  defp message_entries(%Message{role: :tool} = message, index, _state) do
    failed? =
      is_binary(message.content) and
        String.starts_with?(String.trim_leading(message.content), "Error:")

    status = if failed?, do: :failed, else: :completed

    id =
      if is_binary(message.tool_call_id),
        do: "tool:#{message.tool_call_id}",
        else: "message:#{index}:tool"

    [
      tool_entry(
        %{
          name: message.tool_name || "unknown",
          status: status,
          result: if(failed?, do: nil, else: message.content),
          error: if(failed?, do: message.content, else: nil)
        },
        id
      )
    ]
  end

  defp message_entries(_message, _index, _state), do: []

  defp result_status(nil), do: :requested
  defp result_status(%Message{content: "Error:" <> _}), do: :failed
  defp result_status(%Message{}), do: :completed

  defp tool_entry(tool, id) when is_map(tool) do
    name = value(tool, :name) || "unknown"
    status = value(tool, :status) || :requested
    arguments = value(tool, :arguments)
    output = value(tool, :error) || value(tool, :result)
    output = if is_nil(output), do: nil, else: format_value(output)

    entry(:tool, ToolView.title(name, arguments, status),
      id: id,
      source: output || format_value(arguments || %{}),
      tool_output: output,
      tool_name: name,
      tool_arguments: arguments,
      model: value(tool, :model),
      tool_status: status,
      tool_elapsed_ms: value(tool, :elapsed_ms),
      subagent_work: value(tool, :subagent_work),
      subagent_output: value(tool, :subagent_output),
      style: style(:tool)
    )
  end

  defp entry(kind, content, opts) when is_binary(content) do
    %__MODULE__{
      kind: kind,
      content: content,
      label: Keyword.get(opts, :label),
      style: Keyword.get(opts, :style, style(kind)),
      id: Keyword.get(opts, :id),
      source: Keyword.get(opts, :source, content),
      tool_output: Keyword.get(opts, :tool_output),
      tool_name: Keyword.get(opts, :tool_name),
      tool_arguments: Keyword.get(opts, :tool_arguments),
      model: Keyword.get(opts, :model),
      tool_status: Keyword.get(opts, :tool_status),
      tool_elapsed_ms: Keyword.get(opts, :tool_elapsed_ms),
      subagent_work: Keyword.get(opts, :subagent_work),
      subagent_output: Keyword.get(opts, :subagent_output),
      collapsed?: Keyword.get(opts, :collapsed?, false)
    }
  end

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_map(value) or is_list(value) do
    case JSON.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  defp format_value(value), do: inspect(value)

  defp wrap_row(%Line{spans: spans, style: style}, width) do
    units =
      Enum.flat_map(spans, fn %Span{content: content, style: span_style} ->
        for grapheme <- String.graphemes(content), do: {grapheme, span_style}
      end)

    {lines, current, _current_width} =
      Enum.reduce(units, {[], [], 0}, fn {grapheme, span_style},
                                         {lines, current, current_width} ->
        grapheme_width = terminal_width(grapheme)

        if current != [] and current_width + grapheme_width > width do
          {[build_line(Enum.reverse(current), style) | lines], [{grapheme, span_style}],
           grapheme_width}
        else
          {lines, [{grapheme, span_style} | current], current_width + grapheme_width}
        end
      end)

    [build_line(Enum.reverse(current), style) | lines]
    |> Enum.reverse()
  end

  defp build_line([], style), do: Line.new([span("")], style: style)

  defp build_line(units, style) do
    spans =
      units
      |> Enum.chunk_by(fn {_grapheme, span_style} -> span_style end)
      |> Enum.map(fn [{_grapheme, span_style} | _rest] = chunk ->
        content = Enum.map_join(chunk, &elem(&1, 0))
        span(content, span_style)
      end)

    Line.new(spans, style: style)
  end

  defp truncate_line(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end

  defp wrap_text(text, width) do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_line(&1, width))
    |> Enum.join("\n")
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    {lines, current, _current_width} =
      line
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn grapheme, {lines, current, current_width} ->
        grapheme_width = terminal_width(grapheme)

        if current != [] and current_width + grapheme_width > width do
          {[Enum.reverse(current) | lines], [grapheme], grapheme_width}
        else
          {lines, [grapheme | current], current_width + grapheme_width}
        end
      end)

    [Enum.reverse(current) | lines]
    |> Enum.reverse()
    |> Enum.map(&Enum.join/1)
  end

  defp terminal_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      Regex.match?(@zero_width_grapheme, grapheme) -> 0
      Regex.match?(@emoji_presentation, grapheme) -> 2
      0xFE0F in codepoints -> 2
      Enum.any?(codepoints, &wide_codepoint?/1) -> 2
      true -> 1
    end
  end

  defp wide_codepoint?(codepoint) do
    Enum.any?(@wide_codepoint_ranges, fn {first, last} ->
      codepoint >= first and codepoint <= last
    end)
  end

  defp tool_id(tool) do
    value(tool, :tool_call_id) || value(tool, :id) || value(tool, :name) || "unknown"
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Paint is a security boundary. Keep line breaks, turn tabs into spaces, and
  # discard ANSI CSI/OSC/string controls plus other C0 bytes. The original
  # source remains available through source/1 for explicit copy actions.
  defp sanitize_chars([], _mode, acc), do: acc
  defp sanitize_chars([27 | rest], :normal, acc), do: sanitize_chars(rest, :escape, acc)

  defp sanitize_chars([char | rest], :normal, acc) when char == 10,
    do: sanitize_chars(rest, :normal, [char | acc])

  defp sanitize_chars([9 | rest], :normal, acc), do: sanitize_chars(rest, :normal, [32, 32 | acc])

  defp sanitize_chars([char | rest], :normal, acc) when char < 32 or char == 127,
    do: sanitize_chars(rest, :normal, acc)

  defp sanitize_chars([char | rest], :normal, acc),
    do: sanitize_chars(rest, :normal, [char | acc])

  defp sanitize_chars([91 | rest], :escape, acc), do: sanitize_chars(rest, :csi, acc)
  defp sanitize_chars([93 | rest], :escape, acc), do: sanitize_chars(rest, :osc, acc)

  defp sanitize_chars([char | rest], :escape, acc) when char in [?P, ?^, ?_],
    do: sanitize_chars(rest, :string, acc)

  defp sanitize_chars(rest, :escape, acc), do: sanitize_chars(rest, :normal, acc)

  defp sanitize_chars([char | rest], :csi, acc) when char >= 0x40 and char <= 0x7E,
    do: sanitize_chars(rest, :normal, acc)

  defp sanitize_chars([_char | rest], :csi, acc), do: sanitize_chars(rest, :csi, acc)

  defp sanitize_chars([7 | rest], :osc, acc), do: sanitize_chars(rest, :normal, acc)
  defp sanitize_chars([27 | rest], :osc, acc), do: sanitize_chars(rest, :osc_escape, acc)
  defp sanitize_chars([_char | rest], :osc, acc), do: sanitize_chars(rest, :osc, acc)

  defp sanitize_chars([92 | rest], :osc_escape, acc), do: sanitize_chars(rest, :normal, acc)
  defp sanitize_chars([_char | rest], :osc_escape, acc), do: sanitize_chars(rest, :osc, acc)

  defp sanitize_chars([7 | rest], :string, acc), do: sanitize_chars(rest, :normal, acc)
  defp sanitize_chars([27 | rest], :string, acc), do: sanitize_chars(rest, :osc_escape, acc)
  defp sanitize_chars([_char | rest], :string, acc), do: sanitize_chars(rest, :string, acc)
end
