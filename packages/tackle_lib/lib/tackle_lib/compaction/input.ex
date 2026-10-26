defmodule Tackle.Lib.Compaction.Input do
  @moduledoc """
  Bounds the shadowed messages a summarizer reads to a token budget.

  The summarization request carries the system prompt, the tool definitions,
  the shadowed messages, and the directive, and must leave room for the
  summary. Usually the shadowed messages fit and are sent unchanged, so the
  request shares the live request's prompt-cache prefix. When they do not
  (after a provider overflow, or with an oversized tool result), the largest
  messages are shortened to one common size, the smallest that makes the
  whole fit, so small messages stay verbatim:

    * text keeps its beginning and end around a marker naming how much was
      omitted;
    * tool-call arguments over their share become one truncated JSON string
      under `"truncated_arguments"`, keeping the call's id and name so its
      result stays linked;
    * content parts (such as images) are replaced by a note in the text; and
    * provider continuation state is dropped, since an adapter would replay
      it in place of the shortened content.

  Earlier checkpoints are never shortened. The result is only summarizer
  input: the transcript and the model projection are unchanged.
  """

  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call

  # Below this many tokens a shortened message keeps too little to summarize,
  # so a budget that needs a smaller size is reported as too small instead.
  @min_message_tokens 64

  @doc """
  Fits `messages` into `budget` tokens.

  Returns `{:ok, messages, shortened}` with the number of shortened messages
  (0 when they already fit), or `{:error, :summary_input_too_large}` when they
  cannot fit even with every shortenable message at a minimal size.
  """
  @spec fit([Message.t()], integer()) ::
          {:ok, [Message.t()], non_neg_integer()} | {:error, :summary_input_too_large}
  def fit(messages, budget) when is_list(messages) and is_integer(budget) do
    if ContextUsage.estimate_messages(messages) <= budget do
      {:ok, messages, 0}
    else
      shorten(messages, budget)
    end
  end

  defp shorten(messages, budget) do
    sizes = Enum.map(messages, &{&1, ContextUsage.estimate_message(&1)})

    fixed =
      sizes
      |> Enum.filter(fn {message, _size} -> Checkpoint.message?(message) end)
      |> Enum.reduce(0, fn {_message, size}, acc -> acc + size end)

    shortenable =
      for {message, size} <- sizes, not Checkpoint.message?(message), do: size

    case level(shortenable, budget - fixed) do
      level when level >= @min_message_tokens -> settle(sizes, budget, level)
      _too_small -> {:error, :summary_input_too_large}
    end
  end

  # The largest size every shortenable message may keep such that their
  # sizes, each capped there, sum to at most `available`.
  defp level(sizes, available) do
    sorted = Enum.sort(sizes)
    count = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.reduce_while(available, fn {size, index}, remaining ->
      share = div(remaining, count - index)

      if size <= share,
        do: {:cont, remaining - size},
        else: {:halt, {:level, share}}
    end)
    |> case do
      {:level, share} -> share
      _everything_fits -> available
    end
  end

  # Shortening estimates are approximate (framing and rounding), so the
  # level steps down until the whole really fits.
  defp settle(sizes, budget, level) do
    shortened = Enum.map(sizes, fn {message, size} -> shorten_message(message, size, level) end)
    messages = Enum.map(shortened, &elem(&1, 0))

    cond do
      ContextUsage.estimate_messages(messages) <= budget ->
        {:ok, messages, Enum.count(shortened, &elem(&1, 1))}

      level > @min_message_tokens ->
        settle(sizes, budget, max(div(level * 9, 10), @min_message_tokens))

      true ->
        {:error, :summary_input_too_large}
    end
  end

  defp shorten_message(message, size, level) do
    if size <= level or Checkpoint.message?(message),
      do: {message, false},
      else: {truncate(message, level), true}
  end

  defp truncate(%Message{} = message, level) do
    bare = %{
      message
      | content: "",
        parts: [],
        thinking: nil,
        provider_state: nil,
        tool_calls: Enum.map(message.tool_calls || [], &%{&1 | arguments: %{}, raw: nil})
    }

    note = parts_note(message.parts)
    pieces = [content_text(message) | Enum.map(message.tool_calls || [], &arguments_json/1)]
    total = pieces |> Enum.map(&String.length/1) |> Enum.sum()

    # Characters left for the pieces once the bare message is paid for.
    available = max((level - ContextUsage.estimate_message(bare)) * 4 - String.length(note), 0)
    [content | arguments] = Enum.map(pieces, &shorten_text(&1, share(&1, total, available)))

    tool_calls =
      message.tool_calls
      |> List.wrap()
      |> Enum.zip(arguments)
      |> Enum.map(fn {%Call{} = call, json} -> truncated_arguments(call, json) end)

    %{bare | content: note <> content, tool_calls: tool_calls}
  end

  defp content_text(%Message{content: content}) when is_binary(content), do: content
  defp content_text(%Message{}), do: ""

  defp parts_note(parts) when is_list(parts) and parts != [],
    do: "[#{length(parts)} content part(s), such as images, omitted for compaction]\n"

  defp parts_note(_parts), do: ""

  defp arguments_json(%Call{arguments: arguments}) do
    JSON.encode!(arguments)
  rescue
    _error -> inspect(arguments)
  end

  defp share(_text, 0, _available), do: 0
  defp share(text, total, available), do: div(String.length(text) * available, total)

  defp truncated_arguments(%Call{arguments: arguments} = call, json) do
    if json == arguments_json(call),
      do: %{call | arguments: arguments},
      else: %{call | arguments: %{"truncated_arguments" => json}, raw: nil}
  end

  # The marker takes at most this many characters of the kept share.
  @marker_chars 64

  defp shorten_text(text, keep) do
    length = String.length(text)

    if length <= keep do
      text
    else
      kept = max(keep - @marker_chars, 0)
      head = div(kept * 2, 3)
      marker = "\n[… #{length - kept} characters omitted for compaction …]\n"

      String.slice(text, 0, head) <> marker <> String.slice(text, length - (kept - head), length)
    end
  end
end
