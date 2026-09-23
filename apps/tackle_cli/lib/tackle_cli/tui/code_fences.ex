defmodule Tackle.CLI.TUI.CodeFences do
  @moduledoc false

  # Only intercept Elixir fences: tui-markdown already handles other languages,
  # but its bundled syntect syntax set does not include Elixir.
  @spec split(String.t()) :: [{:markdown, String.t()} | {:elixir, String.t()}]
  def split(source) do
    source
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], [], :prose}, &scan_line/2)
    |> finish()
  end

  defp scan_line(line, {parts, current, :prose}) do
    case opening(line) do
      {fence, info} ->
        if elixir?(info) do
          {flush(parts, current, :markdown), [], {:elixir, fence}}
        else
          {parts, [line | current], {:other, fence}}
        end

      nil ->
        {parts, [line | current], :prose}
    end
  end

  defp scan_line(line, {parts, current, {:other, fence}}) do
    if closing?(line, fence),
      do: {parts, [line | current], :prose},
      else: {parts, [line | current], {:other, fence}}
  end

  defp scan_line(line, {parts, current, {:elixir, fence}}) do
    if closing?(line, fence),
      do: {flush(parts, current, :elixir), [], :prose},
      else: {parts, [line | current], {:elixir, fence}}
  end

  defp finish({parts, current, state}) do
    kind = if match?({:elixir, _}, state), do: :elixir, else: :markdown
    parts = flush(parts, current, kind)
    if parts == [], do: [{:markdown, ""}], else: Enum.reverse(parts)
  end

  defp flush(parts, [], _kind), do: parts
  defp flush(parts, lines, kind), do: [{kind, lines |> Enum.reverse() |> Enum.join("\n")} | parts]

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

  defp elixir?(info) do
    token = info |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd()
    String.downcase(token) in ["elixir", "ex", "exs"]
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
