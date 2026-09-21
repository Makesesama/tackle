defmodule Tackle.Web.AgentActivity do
  @moduledoc """
  One line describing what an assistant is doing right now.

  A turn can spend seconds inside a tool before any answer text exists, so a
  surface that only renders messages looks stalled. Both assistant surfaces — the
  review panel and the chat — show this label while a turn is running, which is
  why it lives here rather than in either LiveView.

  The label comes from the `Tackle.Lib.Event` a tool-start carries. It is
  deliberately terse: enough to know the assistant is working and where, not a
  second transcript.
  """

  @max_length 80

  @doc "Describes a tool-start event's data. Falls back to a generic label."
  @spec label(map()) :: String.t()
  def label(%{name: "bash", arguments: %{"command" => command}}) when is_binary(command) do
    "$ " <> first_line(command)
  end

  def label(%{name: "read", arguments: %{"path" => path}}) when is_binary(path) do
    "Reading #{path}"
  end

  def label(%{name: name}) when is_binary(name), do: "Running #{name}"
  def label(_data), do: "Working"

  defp first_line(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||(text)
    |> String.slice(0, @max_length)
  end
end
