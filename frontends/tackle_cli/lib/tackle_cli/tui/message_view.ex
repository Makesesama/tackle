defmodule Tackle.CLI.TUI.MessageView do
  @moduledoc """
  Converts conversation state into typed entries and native ExRatatui widgets.

  The conversation keeps provider messages and transient turn state separate
  from their terminal representation. Assistant content is passed to the
  Markdown widget unchanged; the other entry kinds remain plain Paragraphs so
  lifecycle and tool information is not interpreted as Markdown.
  """

  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Markdown, Paragraph}
  alias Tackle.Lib.Message

  @tool_arguments_limit 240
  @tool_result_limit 500
  @tool_result_lines 6
  @conversation_chunk_rows 64
  @max_markdown_scroll 65_535
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

  @typedoc """
  A terminal conversation entry before it is projected into widgets.

  `:assistant` entries keep `content` as the provider's exact Markdown source.
  Other kinds are intentionally rendered as plain Paragraphs.
  """
  @type kind :: :user | :assistant | :thinking | :tool | :error | :welcome
  @type t :: %__MODULE__{
          kind: kind(),
          content: String.t(),
          label: String.t() | nil,
          style: Style.t()
        }

  @enforce_keys [:kind, :content]
  defstruct [:kind, :content, :label, style: %Style{}]

  @typedoc "A primitive widget and its exact row height in the conversation list."
  @type widget_item :: {struct(), non_neg_integer()}

  @doc """
  Returns the typed entries for one conversation section.

  The section projection is deliberately based on the TUI state rather than on
  provider-specific events, which keeps settled and streaming messages on the
  same rendering path.
  """
  @spec section_entries(map(), atom()) :: [t()]
  def section_entries(state, :settled) do
    messages = state.agent_state.messages || []
    Enum.flat_map(messages, &message_entries/1)
  end

  def section_entries(state, :pending) do
    if state.pending_prompt do
      [entry(:user, "You:\n#{state.pending_prompt}", style: style(:user))]
    else
      []
    end
  end

  def section_entries(state, :tools) do
    Enum.map(state.tool_activity, &tool_entry/1)
  end

  def section_entries(state, :thinking) do
    if state.streaming_thinking == "" do
      []
    else
      [entry(:thinking, "Thinking:\n#{state.streaming_thinking}", style: style(:thinking))]
    end
  end

  def section_entries(state, :response) do
    if state.streaming_response == "" do
      []
    else
      [entry(:assistant, state.streaming_response, label: "Tackle:", style: style(:assistant))]
    end
  end

  def section_entries(state, :error) do
    if state.error do
      [entry(:error, "Error:\n#{state.error}", style: style(:error))]
    else
      []
    end
  end

  @doc "Builds a typed welcome entry used when a session has no messages yet."
  @spec welcome_entry() :: t()
  def welcome_entry do
    entry(
      :welcome,
      "Welcome to Tackle. Type a prompt below to start a session.",
      style: style(:welcome)
    )
  end

  @doc "Converts one typed entry to bounded primitive widgets."
  @spec render_entry(t(), pos_integer()) :: [widget_item()]
  def render_entry(%__MODULE__{kind: :assistant} = entry, width) do
    label_items =
      if entry.label do
        [{%Paragraph{text: entry.label, style: entry.style}, 1}]
      else
        []
      end

    label_items ++ render_markdown(entry, width)
  end

  def render_entry(%__MODULE__{} = entry, width)
      when entry.kind in [:user, :thinking, :tool, :error, :welcome] do
    render_paragraph(entry, width)
  end

  @doc false
  @spec style(kind()) :: Style.t()
  def style(:user), do: %Style{fg: :green}
  def style(:assistant), do: %Style{fg: :white}
  def style(:thinking), do: %Style{fg: :yellow}
  def style(:tool), do: %Style{fg: :cyan}
  def style(:error), do: %Style{fg: :red}
  def style(:welcome), do: %Style{fg: :dark_gray}

  defp render_markdown(%__MODULE__{content: content, style: style} = entry, width) do
    height = Markdown.measure_height(content, width)

    cond do
      height <= @conversation_chunk_rows ->
        [{%Markdown{content: content, style: style}, height}]

      height <= @max_markdown_scroll + 1 ->
        0..(height - 1)//@conversation_chunk_rows
        |> Enum.map(fn scroll_offset ->
          item_height = min(@conversation_chunk_rows, height - scroll_offset)

          {
            %Markdown{
              content: content,
              style: style,
              scroll: {scroll_offset, 0}
            },
            item_height
          }
        end)

      true ->
        # ExRatatui and Ratatui represent Paragraph scroll offsets as u16. A
        # larger offset cannot be encoded, so keep rendering safe and bounded
        # by showing the original source as plain text instead of crashing.
        render_paragraph(entry, width)
    end
  end

  defp render_paragraph(%__MODULE__{} = entry, width) do
    entry.content
    |> wrap_text(width)
    |> String.split("\n", trim: false)
    |> Enum.chunk_every(@conversation_chunk_rows)
    |> Enum.map(fn lines ->
      {%Paragraph{text: Enum.join(lines, "\n"), style: entry.style}, length(lines)}
    end)
  end

  defp message_entries(%Message{role: :user, content: content}) when is_binary(content),
    do: [entry(:user, "You:\n#{content}", style: style(:user))]

  defp message_entries(%Message{role: :assistant} = message) do
    thinking =
      if is_binary(message.thinking) and message.thinking != "" do
        [entry(:thinking, "Thinking:\n#{message.thinking}", style: style(:thinking))]
      else
        []
      end

    content =
      if is_binary(message.content) and message.content != "" do
        [entry(:assistant, message.content, label: "Tackle:", style: style(:assistant))]
      else
        []
      end

    tool_calls = Enum.map(message.tool_calls || [], &tool_call_entry/1)
    thinking ++ content ++ tool_calls
  end

  defp message_entries(%Message{role: :tool} = message) do
    failed? =
      is_binary(message.content) and
        String.starts_with?(String.trim_leading(message.content), "Error:")

    status = if failed?, do: :failed, else: :completed

    [
      tool_entry(%{
        name: message.tool_name || "unknown",
        status: status,
        result: if(failed?, do: nil, else: message.content),
        error: if(failed?, do: message.content, else: nil)
      })
    ]
  end

  defp message_entries(_message), do: []

  defp tool_call_entry(tool_call) do
    name = value(tool_call, :name) || "unknown"
    arguments = value(tool_call, :arguments)

    entry(:tool, "● #{name}" <> format_detail("args", arguments, @tool_arguments_limit),
      style: style(:tool)
    )
  end

  defp tool_entry(%{status: :running} = tool) do
    entry(
      :tool,
      "● #{tool.name}" <>
        format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
        "\n  running",
      style: style(:tool)
    )
  end

  defp tool_entry(%{status: :completed} = tool) do
    entry(
      :tool,
      "✓ #{tool.name}" <>
        format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
        "\n  completed" <>
        format_detail("result", Map.get(tool, :result), @tool_result_limit),
      style: style(:tool)
    )
  end

  defp tool_entry(%{status: :failed} = tool) do
    entry(
      :tool,
      "✗ #{tool.name}" <>
        format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
        "\n  failed" <>
        format_detail("error", Map.get(tool, :error), @tool_result_limit),
      style: style(:tool)
    )
  end

  defp entry(kind, content, opts) when is_binary(content) do
    %__MODULE__{
      kind: kind,
      content: content,
      label: Keyword.get(opts, :label),
      style: Keyword.get(opts, :style, style(kind))
    }
  end

  defp format_detail(_label, value, _limit) when value in [nil, "", %{}], do: ""

  defp format_detail(label, value, limit) do
    preview = value |> format_value() |> truncate_preview(limit) |> indent_lines()
    "\n  #{label}: #{preview}"
  end

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_map(value) or is_list(value) do
    case Tackle.Lib.JSON.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  defp format_value(value), do: inspect(value)

  defp truncate_preview(value, limit) do
    lines = value |> String.trim() |> String.split("\n")
    lines_truncated? = length(lines) > @tool_result_lines
    preview = lines |> Enum.take(@tool_result_lines) |> Enum.join("\n")
    chars_truncated? = String.length(preview) > limit
    preview = if chars_truncated?, do: String.slice(preview, 0, limit), else: preview

    if lines_truncated? or chars_truncated?, do: preview <> "…", else: preview
  end

  defp indent_lines(value), do: String.replace(value, "\n", "\n  ")

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

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
