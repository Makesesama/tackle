defmodule Tackle.Web.ChatMessageView do
  @moduledoc """
  How a chat transcript is shaped for rendering.

  `Tackle.Phoenix.EventReducer` owns the streaming mechanics but refuses to
  decide what a message looks like; this module makes that decision for the chat
  surface. The rule is the one a reader expects from a chat: questions and
  answers are visible, and the work that produced an answer — tool calls, tool
  results, and assistant messages that only reason — is grouped into one
  collapsible block instead of being interleaved with the conversation.

  Answers are rendered as plain text with preserved whitespace rather than as
  markdown: the frontend has no markdown dependency, and an answer that needs to
  be read is usually short and mostly code references. The streaming entry is
  deliberately just accumulated text, so nothing is re-parsed per token.
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

  # Consecutive internal messages are collected into one block, so the template
  # can collapse them behind a single summary. A question, or an answer worth
  # reading, ends the block.
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
  defp internal?(%Message{role: :assistant, content: content}), do: not visible?(content)
  defp internal?(_message), do: false

  defp visible?(content) when is_binary(content), do: String.trim(content) != ""
  defp visible?(_content), do: false

  # A single internal message — a tool result with no answer after it, say — is
  # still internal. Deciding by the block size would render it as an answer.
  defp shape([%Message{} = message]) do
    if internal?(message), do: {:internal, [message]}, else: {:visible, message}
  end

  defp shape(block), do: {:internal, block}
end
