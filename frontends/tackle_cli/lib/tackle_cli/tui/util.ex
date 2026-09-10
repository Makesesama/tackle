defmodule Tackle.CLI.TUI.Util do
  @moduledoc """
  Small shell helpers that have no domain module of their own.

  These are the few operations every pane needs: clamping an index or offset
  into range, rendering an error or exit reason for a notice, shortening text
  to a column budget, and reporting the outcome of a clipboard write. They are
  deliberately free of TUI state beyond the clipboard writer they read.
  """

  alias Tackle.CLI.TUI.State

  @doc "Clamps `value` into the inclusive `minimum..maximum` range."
  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  @doc "Formats an error, exit, or invalid-value reason for display."
  @spec format_reason(term()) :: String.t()
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)

  @doc """
  Shortens `text` to at most `width` graphemes.

  A cut string ends in an ellipsis, which occupies the last column, so the
  result never exceeds `width`.
  """
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, width) do
    if String.length(text) <= width do
      text
    else
      String.slice(text, 0, max(width - 1, 0)) <> "…"
    end
  end

  @doc """
  Copies `text` through the shell's clipboard writer.

  Returns the success notice when the write succeeded, otherwise a failure
  notice carrying the reason, so every copy action reports honestly without
  repeating the same `case`.
  """
  @spec copy_notice(State.t(), String.t(), String.t()) :: String.t()
  def copy_notice(%State{} = state, text, success_notice) do
    case state.clipboard_writer.(text) do
      :ok -> success_notice
      {:error, reason} -> "Copy failed: #{format_reason(reason)}"
      other -> "Copy failed: #{format_reason(other)}"
    end
  end
end
