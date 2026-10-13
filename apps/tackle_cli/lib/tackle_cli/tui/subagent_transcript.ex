defmodule Tackle.CLI.TUI.SubagentTranscript do
  @moduledoc """
  Projects one delegated child's event stream into a conversation timeline.

  The parent session forwards every child event inside `:subagent_progress`.
  This module folds those events into the same timeline items the live `:turn`
  transcript section renders (`:user`, `:thinking`, `:assistant`, and `:tool`),
  so the read-only subagent view reuses `Tackle.CLI.TUI.Conversation` and
  `Tackle.CLI.TUI.MessageView` instead of a second renderer.

  Streamed deltas give live feedback; each canonical `message_end` replaces the
  streamed text of its message, so the projection stays faithful when a
  provider's terminal payload differs from its deltas. Live tool output is
  bounded the same way the parent's live cards are, while settled results keep
  the content the child actually received.

  The projection only knows what this frontend observed: a session resumed
  after the child ran has no transcript to show.
  """

  alias Tackle.CLI.TUI.ReviewCall
  alias Tackle.Lib.{Event, Message}

  @max_live_tool_output_bytes 50 * 1_024
  # Settled output is kept per card for the view's previews and copy; larger
  # results are cut so many chatty children cannot grow the shell without bound.
  @max_settled_tool_output_bytes 64 * 1_024

  @typedoc "Timeline items plus the bookkeeping needed to place streamed deltas."
  @type t :: %__MODULE__{
          timeline: [map()],
          active_message_id: String.t() | nil,
          error: String.t() | nil
        }

  defstruct timeline: [], active_message_id: nil, error: nil

  @doc "Returns an empty transcript."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds one child event into the transcript.

  Accepts `Tackle.Lib.Event` structs and plain `%{type: atom, data: map}` maps;
  anything else, and event types without a transcript meaning, leave the
  transcript unchanged.
  """
  @spec apply(t() | nil, term()) :: t()
  def apply(nil, event), do: __MODULE__.apply(new(), event)

  def apply(%__MODULE__{} = transcript, %Event{type: type, id: id, data: data})
      when is_map(data),
      do: project(transcript, type, id, data)

  def apply(%__MODULE__{} = transcript, %{type: type, data: data} = event)
      when is_atom(type) and is_map(data),
      do: project(transcript, type, Map.get(event, :id), data)

  def apply(%__MODULE__{} = transcript, _event), do: transcript

  # -- messages ------------------------------------------------------------

  defp project(transcript, :message_start, id, %{role: :assistant}) when is_binary(id),
    do: %{transcript | active_message_id: id}

  defp project(transcript, :message_delta, id, %{delta: delta} = data)
       when is_binary(delta) and delta != "" do
    message_id = id || transcript.active_message_id

    case Map.get(data, :field) do
      :reasoning ->
        put_timeline(transcript, append_text(transcript.timeline, :thinking, delta, message_id))

      field when field in [nil, :content] ->
        put_timeline(transcript, append_text(transcript.timeline, :assistant, delta, message_id))

      _other ->
        transcript
    end
  end

  defp project(transcript, :message_end, _id, %{message: %Message{role: :user} = message}) do
    cond do
      Enum.any?(transcript.timeline, &(&1[:message_id] == message.id)) ->
        transcript

      is_binary(message.content) and message.content != "" ->
        item = %{
          kind: :user,
          content: message.content,
          id: "subagent:#{message.id}:user",
          message_id: message.id
        }

        put_timeline(transcript, append(transcript.timeline, item))

      true ->
        transcript
    end
  end

  defp project(transcript, :message_end, _id, %{message: %Message{role: :assistant} = message}) do
    timeline =
      transcript.timeline
      |> reconcile_message(message)
      |> put_requested_calls(message.tool_calls || [])

    %{transcript | timeline: timeline, active_message_id: nil}
  end

  defp project(transcript, :message_end, _id, %{message: %Message{role: :tool} = message}) do
    id = message.tool_call_id

    case find_tool(transcript.timeline, id) do
      %{status: status} when status in [:completed, :failed] ->
        transcript

      _open ->
        failed? = is_binary(message.content) and String.starts_with?(message.content, "Error:")

        put_tool(transcript, %{
          id: id,
          name: message.tool_name,
          status: if(failed?, do: :failed, else: :completed),
          result: if(failed?, do: nil, else: bound_settled(message.content)),
          error: if(failed?, do: bound_settled(message.content), else: nil)
        })
    end
  end

  # -- tools ---------------------------------------------------------------

  defp project(transcript, :tool_start, _id, data) do
    put_tool(transcript, %{
      id: value(data, :tool_call_id),
      name: tool_name(data),
      arguments: value(data, :arguments),
      status: :running
    })
  end

  defp project(transcript, :tool_progress, _id, data) do
    id = value(data, :tool_call_id)
    current = find_tool(transcript.timeline, id)

    case value(data, :delta) || value(data, :output) do
      _late when is_map(current) and current.status in [:completed, :failed] ->
        transcript

      # `review_changes` reports structured progress instead of text.
      nil when is_map(current) and current.name == "review_changes" ->
        project_review(transcript, current, value(data, :review))

      delta when is_binary(delta) and delta != "" ->
        output = append_bounded(value(current, :result), delta, @max_live_tool_output_bytes)
        put_tool(transcript, %{id: id, name: tool_name(data), status: :running, result: output})

      _other ->
        transcript
    end
  end

  defp project(transcript, :tool_execution_end, _id, %{status: status} = data)
       when status in [:completed, :failed],
       do: settle_tool(transcript, data, status)

  defp project(transcript, :tool_end, _id, data), do: settle_tool(transcript, data, :completed)
  defp project(transcript, :tool_error, _id, data), do: settle_tool(transcript, data, :failed)

  # -- turn outcome --------------------------------------------------------

  defp project(transcript, :error, _id, data) do
    case value(data, :error) do
      error when is_binary(error) and error != "" -> %{transcript | error: error}
      _other -> transcript
    end
  end

  defp project(transcript, :turn_end, _id, data) do
    if value(data, :status) == :cancelled,
      do: interrupt_open_tools(transcript),
      else: transcript
  end

  defp project(transcript, :turn_cancelled, _id, _data), do: interrupt_open_tools(transcript)

  defp project(transcript, _type, _id, _data), do: transcript

  # -- helpers -------------------------------------------------------------

  defp settle_tool(transcript, data, status) do
    result = value(data, :result)
    error = value(data, :error) || value(data, :reason)

    put_tool(transcript, %{
      id: value(data, :tool_call_id),
      name: tool_name(data),
      status: status,
      result: if(status == :completed, do: bound_settled(result)),
      error: if(status == :failed, do: error |> format_error() |> bound_settled())
    })
  end

  @doc """
  Freezes calls that are still requested or running as interrupted.

  A child that was cancelled, timed out, or crashed never settles its open
  calls, so the view must not keep a spinner for work that will not finish.
  """
  @spec interrupt_open_tools(t()) :: t()
  def interrupt_open_tools(%__MODULE__{} = transcript) do
    # Unchanged transcripts are returned as-is so callers can compare by identity.
    if Enum.any?(transcript.timeline, &open_tool?/1) do
      timeline =
        Enum.map(transcript.timeline, fn item ->
          if open_tool?(item),
            do: Map.merge(item, %{status: :failed, error: "Interrupted"}),
            else: item
        end)

      put_timeline(transcript, timeline)
    else
      transcript
    end
  end

  defp open_tool?(%{kind: :tool, status: status}), do: status in [:requested, :running]
  defp open_tool?(_item), do: false

  defp put_requested_calls(timeline, calls) do
    Enum.reduce(calls, timeline, fn call, acc ->
      id = value(call, :id)

      if is_binary(id) and is_nil(find_tool(acc, id)) do
        append(acc, %{
          kind: :tool,
          id: id,
          name: value(call, :name) || "unknown",
          arguments: value(call, :arguments),
          status: :requested
        })
      else
        acc
      end
    end)
  end

  # Cards are keyed by call id; an event without one cannot be placed safely
  # and would otherwise add a new card that shares an entry id with others.
  defp put_tool(transcript, %{id: id}) when not is_binary(id), do: transcript

  defp put_tool(transcript, %{id: id} = updates) do
    updates = Enum.reject(updates, fn {_key, value} -> is_nil(value) end) |> Map.new()

    timeline =
      case Enum.find_index(transcript.timeline, &same_tool?(&1, id)) do
        nil ->
          item = Map.merge(%{kind: :tool, name: "unknown", status: :running}, updates)
          append(transcript.timeline, item)

        index ->
          List.update_at(transcript.timeline, index, &Map.merge(&1, updates))
      end

    put_timeline(transcript, timeline)
  end

  defp project_review(transcript, current, %{} = review) do
    previous = Map.get(current, :review) || ReviewCall.new()
    model = ReviewCall.apply(previous, review)

    if model === previous,
      do: transcript,
      else: put_tool(transcript, %{id: current.id, review: model})
  end

  defp project_review(transcript, _current, _review), do: transcript

  defp find_tool(timeline, id), do: Enum.find(timeline, &same_tool?(&1, id))

  defp same_tool?(%{kind: :tool, id: id}, id) when is_binary(id), do: true
  defp same_tool?(_item, _id), do: false

  defp reconcile_message(timeline, %Message{id: id} = message) do
    canonical = canonical_entries(message)
    index = Enum.find_index(timeline, &(&1[:message_id] == id))

    cond do
      is_integer(index) ->
        remaining = Enum.reject(timeline, &(&1[:message_id] == id))
        Enum.take(remaining, index) ++ canonical ++ Enum.drop(remaining, index)

      true ->
        timeline ++ canonical
    end
  end

  defp canonical_entries(%Message{} = message) do
    thinking = text_item(:thinking, message.thinking, message.id)

    assistant =
      case text_item(:assistant, message.content, message.id) do
        [item] -> [Map.put(item, :final?, Message.final_answer?(message))]
        [] -> []
      end

    thinking ++ assistant
  end

  defp text_item(kind, content, message_id) when is_binary(content) and content != "",
    do: [text_entry(kind, content, message_id)]

  defp text_item(_kind, _content, _message_id), do: []

  defp append_text(timeline, kind, delta, message_id) do
    case List.last(timeline) do
      %{kind: ^kind, message_id: ^message_id} = last ->
        List.replace_at(timeline, -1, %{last | content: last.content <> delta})

      _other ->
        append(timeline, text_entry(kind, delta, message_id))
    end
  end

  defp text_entry(kind, content, message_id) when is_binary(message_id),
    do: %{
      kind: kind,
      content: content,
      message_id: message_id,
      id: "subagent:#{message_id}:#{kind}"
    }

  defp text_entry(kind, content, _message_id),
    do: %{kind: kind, content: content, message_id: nil}

  defp put_timeline(transcript, timeline), do: %{transcript | timeline: timeline}

  defp append(list, item), do: list ++ [item]

  defp append_bounded(current, delta, max_bytes) do
    content = if(is_binary(current), do: current, else: "") <> delta

    if byte_size(content) <= max_bytes,
      do: content,
      else: valid_tail(content, byte_size(content) - max_bytes)
  end

  defp valid_tail(content, start) do
    tail = binary_part(content, start, byte_size(content) - start)

    cond do
      String.valid?(tail) -> tail
      start < byte_size(content) -> valid_tail(content, start + 1)
      true -> ""
    end
  end

  defp bound_settled(text)
       when is_binary(text) and byte_size(text) > @max_settled_tool_output_bytes do
    head = valid_head(text, @max_settled_tool_output_bytes)
    head <> "\n… (#{byte_size(text) - byte_size(head)} more bytes not kept by the subagent view)"
  end

  defp bound_settled(text), do: text

  defp valid_head(text, size) do
    head = binary_part(text, 0, size)
    if String.valid?(head) or size == 0, do: head, else: valid_head(text, size - 1)
  end

  defp tool_name(data), do: value(data, :name) || value(data, :tool_name)

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
