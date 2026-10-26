defmodule Tackle.Lib.Messages do
  @moduledoc """
  Converts a Tackle.Lib conversation (a list of `%Tackle.Lib.Message{}`) into a
  provider-neutral **structured message array** — the shape mature agent
  harnesses send to chat-completion APIs.

  Tackle.Lib's loop keeps the conversation as typed messages (user / assistant /
  tool) with native `tool_calls` and `tool_call_id` linkage already populated.
  Historically the loop flattened that history into a single `user` string,
  which discarded turn structure, tool-call/result linkage, and the ability for
  providers to prompt-cache a stable prefix. This module replaces that flatten
  step: each `%Message{}` becomes its own role-tagged map.

  The output is intentionally provider-neutral (OpenAI/OpenRouter-shaped, the de
  facto standard): each entry is a map with `:role` plus the fields relevant to
  that role. Adapters lower these into their wire format.

  ## Shapes

      # user / final assistant
      %{role: :user, content: "..."}
      %{role: :assistant, content: "..."}

      # assistant turn that called tools (content may be nil). Adapters may also
      # receive opaque `provider_state` that they must validate before replay.
      %{
        role: :assistant,
        content: nil,
        tool_calls: [
          %{id: "call_1", type: "function",
            function: %{name: "search", arguments: "{\\"q\\":\\"cats\\"}"}}
        ]
      }

      # tool result, linked back to the call by id
      %{role: :tool, tool_call_id: "call_1", name: "search", content: "..."}

  A tool result that read extra content (for example an image) carries it in the
  message's `:parts`, and its `:content` becomes the provider-neutral part array
  instead of a string:

      %{role: :tool, tool_call_id: "call_1", name: "read",
        content: [
          %{"type" => "text", "text" => "Read image report.png (image/png, 12.0KB)."},
          %{"type" => "image", "media_type" => "image/png", "data" => "iVBORw0KG..."}
        ]}

  Tool-call `arguments` are emitted as a JSON **string** (the OpenAI tool-call
  convention), not a map.
  """

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError

  @doc """
  Converts a list of `%Tackle.Lib.Message{}` into provider-neutral structured maps.

  Empty/blank assistant placeholders (no content and no tool calls) are dropped
  so the provider never sees a degenerate turn.
  """
  @spec to_provider(list(Message.t())) :: [map()]
  def to_provider(messages) when is_list(messages) do
    messages
    |> Enum.map(&to_provider_message/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns assistant tool calls that have no matching tool result message.

  Providers reject a request whose history contains an assistant tool call
  without its tool result, so an interrupted run must settle these before the
  next provider call (see `interrupted_results/3`). Calls are returned in
  transcript order; a call without an id cannot be paired with a result and is
  skipped, as is a repeated id.
  """
  @spec unresolved_tool_calls([Message.t()]) :: [Call.t()]
  def unresolved_tool_calls(messages) when is_list(messages) do
    # One pass over the history: pending calls are keyed by id with the
    # position they were made at, so the result keeps transcript order.
    {pending, _position} =
      Enum.reduce(messages, {%{}, 0}, fn
        %Message{role: :assistant, tool_calls: calls}, acc ->
          Enum.reduce(calls, acc, &put_pending_call/2)

        %Message{role: :tool, tool_call_id: id}, {pending, position} when is_binary(id) ->
          {Map.delete(pending, id), position}

        _message, acc ->
          acc
      end)

    pending
    |> Map.values()
    |> Enum.sort_by(fn {position, _call} -> position end)
    |> Enum.map(fn {_position, call} -> call end)
  end

  defp put_pending_call(%Call{id: id} = call, {pending, position})
       when is_binary(id) and not is_map_key(pending, id),
       do: {Map.put(pending, id, {position, call}), position + 1}

  defp put_pending_call(%Call{}, acc), do: acc

  @doc """
  Builds the synthetic results that settle the unresolved tool calls of
  `messages` (see `unresolved_tool_calls/1`): one tool result message per
  call, in transcript order, whose content is the model-facing error of
  `Tackle.Lib.Tool.Error.interrupted/3` for `outcome`.

  The messages are only built; appending, persisting, and reporting them is
  up to the caller.

  ## Options
    * `:id_generator` - zero-arity function returning a message id
  """
  @spec interrupted_results([Message.t()], ToolError.interrupted_outcome(), keyword()) ::
          [Message.t()]
  def interrupted_results(messages, outcome, opts \\ []) when is_list(messages) do
    messages
    |> unresolved_tool_calls()
    |> Enum.map(fn %Call{id: id, name: name} ->
      error = ToolError.interrupted(id, name, outcome)
      Message.tool_result(id, name, error.content, Keyword.take(opts, [:id_generator]))
    end)
  end

  @doc """
  Converts a single `%Tackle.Lib.Message{}` into a provider-neutral structured map,
  or `nil` if the message carries nothing meaningful to send.
  """
  @spec to_provider_message(Message.t()) :: map() | nil
  def to_provider_message(%Message{role: :user, content: content}) do
    %{role: :user, content: content || ""}
  end

  def to_provider_message(%Message{role: :tool} = message) do
    %{
      role: :tool,
      tool_call_id: message.tool_call_id,
      name: message.tool_name,
      content: tool_content(message)
    }
  end

  def to_provider_message(%Message{role: :assistant} = message) do
    tool_calls = encode_tool_calls(message.tool_calls, message.id || :erlang.phash2(message))

    provider_message =
      cond do
        tool_calls != [] ->
          %{role: :assistant, content: message.content, tool_calls: tool_calls}

        is_binary(message.content) and message.content != "" ->
          %{role: :assistant, content: message.content}

        true ->
          # An assistant turn with neither content nor tool calls carries nothing
          # the provider can use; drop it rather than emit an empty turn.
          nil
      end

    maybe_put_provider_state(provider_message, message.provider_state)
  end

  def to_provider_message(_), do: nil

  # A tool result without extra parts stays a plain string. With parts, the text
  # projection becomes the leading text part of a provider-neutral part array.
  defp tool_content(%Message{content: content, parts: parts}) do
    text = content || ""

    case List.wrap(parts) do
      [] -> text
      parts when text == "" -> parts
      parts -> [%{"type" => "text", "text" => text} | parts]
    end
  end

  defp maybe_put_provider_state(nil, _provider_state), do: nil

  defp maybe_put_provider_state(message, %{} = provider_state),
    do: Map.put(message, :provider_state, provider_state)

  defp maybe_put_provider_state(message, _provider_state), do: message

  defp encode_tool_calls(tool_calls, message_id) do
    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {%Call{} = call, index} ->
      %{
        id: tool_call_id(call, message_id, index),
        type: "function",
        function: %{name: call.name, arguments: JSON.encode!(call.arguments)}
      }
    end)
  end

  defp tool_call_id(%Call{id: id}, _message_id, _index) when is_binary(id) and id != "", do: id

  # The loop gives every call an id, so only foreign history lacks one. Derive
  # it from the message (its id, or a hash of a message built without one) so
  # every request sends the same id: a random one would change the request
  # prefix each time and defeat provider prompt caching.
  defp tool_call_id(%Call{}, message_id, index), do: "call_#{message_id}_#{index}"
end
