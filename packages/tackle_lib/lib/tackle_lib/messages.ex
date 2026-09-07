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

      # assistant turn that called tools (content may be nil)
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

  Tool-call `arguments` are emitted as a JSON **string** (the OpenAI tool-call
  convention), not a map.
  """

  alias Tackle.Lib.Message

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
      content: message.content || ""
    }
  end

  def to_provider_message(%Message{role: :assistant} = message) do
    tool_calls = encode_tool_calls(message.tool_calls)

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
  end

  def to_provider_message(_), do: nil

  defp encode_tool_calls(nil), do: []
  defp encode_tool_calls([]), do: []

  defp encode_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &encode_tool_call/1)
  end

  defp encode_tool_calls(_), do: []

  defp encode_tool_call(tool_call) do
    %{
      id: tool_call_id(tool_call),
      type: "function",
      function: %{
        name: tool_call_name(tool_call),
        arguments: encode_arguments(tool_call_arguments(tool_call))
      }
    }
  end

  defp tool_call_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp tool_call_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  # Fall back to a deterministic-ish id so the call still links to its result.
  defp tool_call_id(_), do: Tackle.Lib.ID.uuid4()

  defp tool_call_name(%{name: name}) when is_binary(name), do: name
  defp tool_call_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_call_name(_), do: nil

  defp tool_call_arguments(%{arguments: args}), do: args
  defp tool_call_arguments(%{"arguments" => args}), do: args
  defp tool_call_arguments(_), do: %{}

  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(args) when is_map(args), do: Tackle.Lib.JSON.encode!(args)
  defp encode_arguments(_), do: "{}"
end
