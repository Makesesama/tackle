defmodule Tackle.Web.AgentThreads do
  @moduledoc """
  Groups a conversation into the threads shown under the code they ask about.

  The conversation is one linear transcript shared by every viewer of a pull
  request, but the UI shows it as per-line threads: a question asked about line
  134 belongs under line 134, together with the answers it produced. This module
  turns the transcript back into that shape.

  A thread starts at a question and runs until the next one, so every answer
  lands in the thread that prompted it. Work that produced no answer for the
  reader — tool calls and their results — is counted rather than listed, because
  a reviewer reading a diff wants the answer, not the assistant's search history.

  Threads are keyed by `Tackle.Web.Anchor`, so the diff component can look up
  comments and threads with one key. A question about one line and a question
  about a range ending on that line share a key: the range's thread hangs under
  its last line.
  """

  alias Tackle.Lib.Message
  alias Tackle.Web.Anchor

  @typedoc "Where a question was asked, as `Tackle.Web.Anchor` describes it."
  @type anchor :: Anchor.at()

  @typedoc "The key a thread is grouped under; see `key/1`."
  @type key :: {String.t(), :new | :old, pos_integer()} | :general

  @typedoc "A question, the answers it produced, and how much work they took."
  @type thread :: %{
          anchor: anchor(),
          question: Message.t(),
          replies: [Message.t()],
          steps: non_neg_integer()
        }

  @doc """
  The key a thread is filed under: `{path, side, last}`, or `:general`.

  A range is keyed by its last line, so its answer hangs under the end of the
  selection. Questions asked without picking a line are filed under `:general`,
  which the UI renders as a conversation of its own rather than against the diff.
  """
  @spec key(term()) :: key()
  def key(anchor), do: Anchor.key(anchor)

  @doc """
  Builds the conversation's threads, oldest question first.

  Messages before the first question — there should be none — are ignored.
  """
  @spec all([Message.t()], %{optional(String.t()) => anchor()}) :: [thread()]
  def all(messages, anchors) when is_list(messages) and is_map(anchors) do
    starts = starts(messages, anchors)
    total = length(messages)

    starts
    |> Enum.with_index()
    |> Enum.map(fn {{index, anchor, question}, position} ->
      replies = Enum.slice(messages, index + 1, next_index(starts, position, total) - index - 1)

      %{
        anchor: anchor,
        question: question,
        replies: Enum.filter(replies, &visible?/1),
        steps: Enum.count(replies, &(not visible?(&1)))
      }
    end)
  end

  @doc "Groups threads by `key/1`, keeping the order they were asked in."
  @spec by_anchor([thread()]) :: %{key() => [thread()]}
  def by_anchor(threads) when is_list(threads) do
    Enum.reduce(threads, %{}, fn thread, grouped ->
      Map.update(grouped, key(thread.anchor), [thread], &(&1 ++ [thread]))
    end)
  end

  @doc """
  The last question's anchor, which is where a streaming answer belongs.

  At most one turn runs per conversation, so the answer being streamed is always
  the reply to the most recent question.
  """
  @spec active_anchor([thread()]) :: anchor() | nil
  def active_anchor([]), do: nil
  def active_anchor(threads), do: threads |> List.last() |> Map.fetch!(:anchor)

  @doc """
  Pairs the in-flight streaming entries with the thread they answer.

  Returns `%{anchor_key => entry}`, which is what the diff component looks up: an
  answer being streamed belongs under the question that asked for it, exactly
  like a finished one.
  """
  @spec streaming([thread()], %{optional(String.t()) => term()}) :: %{key() => term()}
  def streaming(threads, streaming_messages)
      when is_list(threads) and is_map(streaming_messages) do
    case {active_anchor(threads), Map.values(streaming_messages)} do
      {nil, _entries} -> %{}
      {_anchor, []} -> %{}
      {anchor, [entry | _rest]} -> %{key(anchor) => entry}
    end
  end

  defp starts(messages, anchors) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%Message{role: :user, id: id} = message, index} when is_binary(id) ->
        case Map.fetch(anchors, id) do
          {:ok, anchor} -> [{index, anchor, message}]
          :error -> []
        end

      {_message, _index} ->
        []
    end)
  end

  defp next_index(starts, position, total) do
    case Enum.at(starts, position + 1) do
      {index, _anchor, _question} -> index
      nil -> total
    end
  end

  defp visible?(%Message{role: :assistant, content: content}) when is_binary(content) do
    String.trim(content) != ""
  end

  defp visible?(_message), do: false
end
