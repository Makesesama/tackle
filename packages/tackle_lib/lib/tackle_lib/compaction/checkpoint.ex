defmodule Tackle.Lib.Compaction.Checkpoint do
  @moduledoc """
  The synthetic checkpoint a compaction puts at the head of the model context,
  and the one way a committed compaction is applied to a message list.

  A checkpoint is a user message whose content starts with `marker/0`, then a
  framing paragraph, then the summary body. Its id is the compaction's id.

  `apply_compaction/2` is shared by the live install (`Tackle.Lib.Compaction`)
  and by rebuilding a branch's context from its entries
  (`Tackle.Lib.Tree.model_context/2`), so both always agree.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message

  @marker "[[context-checkpoint]]"

  @doc "Returns the marker that identifies a synthetic checkpoint message."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Builds the checkpoint message for one summary."
  @spec message(String.t(), String.t()) :: Message.t()
  def message(compaction_id, summary) when is_binary(summary) do
    Message.user(content(summary), id: compaction_id)
  end

  @doc "Returns true when `message` is a synthetic checkpoint."
  @spec message?(Message.t() | nil) :: boolean()
  def message?(%Message{role: :user, content: content}) when is_binary(content),
    do: String.starts_with?(content, @marker)

  def message?(_message), do: false

  @doc "Returns the summary body of a checkpoint message, or nil for any other message."
  @spec body(Message.t() | nil) :: String.t() | nil
  def body(%Message{} = message) do
    if message?(message) do
      case String.split(message.content, "\n\n", parts: 2) do
        [_header, body] -> String.trim_trailing(body)
        [_header] -> nil
      end
    end
  end

  def body(_message), do: nil

  @doc """
  Returns the checkpoint's framing without a summary: what every checkpoint
  costs on top of its summary.
  """
  @spec framing() :: String.t()
  def framing, do: content("")

  @doc """
  Applies a committed compaction to the messages it was planned from.

  The shadowed prefix (`record.shadowed_message_ids`, which starts with any
  earlier checkpoint) is replaced by the record's checkpoint. The retained
  tail keeps its content and tool linkage, but loses its usage and provider
  continuation state, which described requests from before the compaction.
  """
  @spec apply_compaction([Message.t()], Record.t()) :: [Message.t()]
  def apply_compaction(messages, %Record{} = record) when is_list(messages) do
    shadowed = MapSet.new(record.shadowed_message_ids)

    retained =
      messages
      |> Enum.drop_while(&MapSet.member?(shadowed, &1.id))
      |> Enum.map(&%{&1 | token_usage: nil, provider_state: nil})

    [record.summary_message | retained]
  end

  defp content(summary) do
    """
    #{@marker}
    Earlier conversation in this session was compacted into the background summary below. Treat it as established context, continue from the retained messages that follow, and do not repeat it to the user.

    #{summary}
    """
  end
end
