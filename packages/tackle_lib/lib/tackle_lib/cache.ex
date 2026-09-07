defmodule Tackle.Lib.Cache do
  @moduledoc """
  Provider prompt-caching breakpoints for the stable request prefix.

  Stateless chat-completion APIs re-send the system prompt + every tool
  definition on every step of a ReAct loop. That repeated prefix is the dominant
  input-token cost of a multi-step agent turn. Anthropic-style providers
  (including Anthropic via OpenRouter) let you mark a stable prefix with a
  `cache_control` breakpoint so the cached portion is billed at a small fraction
  of the input cost on subsequent calls that reuse the same prefix.

  This module attaches those breakpoints in the de-facto OpenAI/Anthropic shape:

    * **System message** — its string content becomes a single text content-part
      carrying `cache_control: %{type: "ephemeral"}`.
    * **Last tool definition** — caches the entire (stable, alphabetically
      ordered) tool array up to and including that breakpoint.

  Marking only the system block and the final tool keeps us within Anthropic's
  hard cap of 4 cache breakpoints per request while covering the two biggest
  stable segments. The conversation tail is intentionally NOT cached here: it
  changes every step and would waste a breakpoint.

  Caching is opt-in; pass `cache: true` (or `cache_control: %{...}`) so providers
  that ignore the marker are unaffected.
  """

  @ephemeral %{type: "ephemeral"}

  @doc """
  Returns the cache_control marker to use, or `nil` when caching is disabled.

  Accepts either `cache: true` (use the default ephemeral marker) or an explicit
  `cache_control: marker` override.
  """
  @spec control(keyword()) :: map() | nil
  def control(opts) do
    cond do
      is_map(Keyword.get(opts, :cache_control)) -> Keyword.get(opts, :cache_control)
      Keyword.get(opts, :cache, false) == true -> @ephemeral
      true -> nil
    end
  end

  @doc """
  Marks the system message's content with a cache_control breakpoint.

  The system message's string content is lifted into a single text content-part
  carrying the marker. A no-op when `control` is nil or there is no system
  message. If the system content is already a list of parts, the marker is added
  to the last part.
  """
  @spec mark_system([map()], map() | nil) :: [map()]
  def mark_system(messages, nil), do: messages

  def mark_system(messages, control) when is_list(messages) do
    index = Enum.find_index(messages, &(message_role(&1) == :system))

    case index do
      nil -> messages
      i -> List.update_at(messages, i, &mark_system_message(&1, control))
    end
  end

  @doc """
  Marks the last tool definition with a cache_control breakpoint.

  Caches the whole tool array (the stable prefix) up to the final tool. A no-op
  when `control` is nil or there are no tools.
  """
  @spec mark_last_tool([map()], map() | nil) :: [map()]
  def mark_last_tool(tools, nil), do: tools
  def mark_last_tool([], _control), do: []

  def mark_last_tool(tools, control) when is_list(tools) do
    last_index = length(tools) - 1
    List.update_at(tools, last_index, &Map.put(&1, :cache_control, control))
  end

  defp mark_system_message(message, control) do
    parts = content_parts(message_content(message))

    parts =
      case parts do
        [] -> [%{type: "text", text: "", cache_control: control}]
        _ -> List.update_at(parts, length(parts) - 1, &Map.put(&1, :cache_control, control))
      end

    put_content(message, parts)
  end

  defp content_parts(content) when is_binary(content), do: [%{type: "text", text: content}]
  defp content_parts(content) when is_list(content), do: content
  defp content_parts(_), do: []

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}) when is_binary(role), do: String.to_existing_atom(role)
  defp message_role(_), do: nil

  defp message_content(%{content: content}), do: content
  defp message_content(%{"content" => content}), do: content
  defp message_content(_), do: nil

  defp put_content(%{role: _} = message, content) when is_map_key(message, :content),
    do: %{message | content: content}

  defp put_content(message, content), do: Map.put(message, :content, content)
end
