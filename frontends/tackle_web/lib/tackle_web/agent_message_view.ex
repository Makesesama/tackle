defmodule Tackle.Web.AgentMessageView do
  @moduledoc """
  How the assistant's messages are shaped for rendering.

  `Tackle.Phoenix.EventReducer` owns the streaming mechanics but refuses to
  decide what a message looks like; this module makes that decision for this
  host. Answers are rendered as plain text with preserved whitespace rather than
  as markdown, because rendering markdown would mean another dependency and the
  answers are short, technical and mostly code references.

  The streaming entry is deliberately just accumulated text: the reducer appends
  deltas to it and the template renders it, so nothing is re-parsed per token.
  """

  @behaviour Tackle.Phoenix.MessageView

  alias Tackle.Lib.Message

  @impl true
  def group_messages(messages) when is_list(messages) do
    messages
    |> Enum.chunk_while([], &chunk/2, &finish/1)
  end

  @impl true
  def new_streaming_message, do: %{content: ""}

  @impl true
  def append_streaming_delta(entry, delta) when is_binary(delta) do
    Map.update(entry, :content, delta, &(&1 <> delta))
  end

  # Consecutive assistant and tool messages with nothing to show a reader are
  # collected into one internal block, so the template can collapse them. A user
  # message, or an assistant message with an answer, ends the block.
  defp chunk(message, []), do: {:cont, [message]}

  defp chunk(message, block) do
    if internal?(message) and Enum.all?(block, &internal?/1) do
      {:cont, [message | block]}
    else
      {:cont, shape(Enum.reverse(block)), [message]}
    end
  end

  defp finish([]), do: {:cont, []}
  defp finish(block), do: {:cont, shape(Enum.reverse(block)), []}

  defp internal?(%Message{role: :tool}), do: true

  defp internal?(%Message{role: :assistant, content: content}) when is_binary(content) do
    String.trim(content) == ""
  end

  defp internal?(_message), do: false

  defp shape([%Message{} = message]), do: {:visible, message}
  defp shape(block), do: {:internal, block}
end
