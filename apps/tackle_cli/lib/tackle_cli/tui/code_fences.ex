defmodule Tackle.CLI.TUI.CodeFences do
  @moduledoc false

  # Render fenced code on the same surface regardless of language. The Markdown
  # renderer does not apply a background across highlighted code blocks.
  @spec split(String.t()) :: [{:markdown, String.t()} | {:code, String.t(), String.t()}]
  def split(source) do
    source
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], [], :prose}, &scan_line/2)
    |> finish()
  end

  defp scan_line(line, {parts, current, :prose}) do
    case opening(line) do
      {fence, info} ->
        {flush(parts, current, :markdown), [], {:code, fence, language(info)}}

      nil ->
        {parts, [line | current], :prose}
    end
  end

  defp scan_line(line, {parts, current, {:code, fence, language}}) do
    if closing?(line, fence),
      do: {flush(parts, current, {:code, language}), [], :prose},
      else: {parts, [line | current], {:code, fence, language}}
  end

  defp finish({parts, current, state}) do
    kind =
      case state do
        {:code, _, language} -> {:code, language}
        :prose -> :markdown
      end

    parts = flush(parts, current, kind)
    if parts == [], do: [{:markdown, ""}], else: Enum.reverse(parts)
  end

  defp flush(parts, [], _kind), do: parts

  defp flush(parts, lines, kind) do
    content = lines |> Enum.reverse() |> Enum.join("\n")

    segment =
      case kind do
        {:code, language} -> {:code, language, content}
        :markdown -> {:markdown, content}
      end

    [segment | parts]
  end

  defp opening(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      [_, fence, info] ->
        # Backtick fences cannot contain backticks in their info string.
        if String.starts_with?(fence, "`") and String.contains?(info, "`"),
          do: nil,
          else: {fence, info}

      _ ->
        nil
    end
  end

  defp language(info) do
    token = info |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd() |> String.downcase()
    if token in ["ex", "exs"], do: "elixir", else: token
  end

  defp closing?(line, fence) do
    marker = String.first(fence)

    case Regex.run(~r/^ {0,3}([`~]{3,})[ \t]*$/, line) do
      [_, end_fence] ->
        String.first(end_fence) == marker and
          String.length(end_fence) >= String.length(fence) and
          Enum.all?(String.graphemes(end_fence), &(&1 == marker))

      _ ->
        false
    end
  end
end
