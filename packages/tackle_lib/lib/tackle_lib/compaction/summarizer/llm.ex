defmodule Tackle.Lib.Compaction.Summarizer.LLM do
  @moduledoc """
  Default summarizer: one tool-free generation through the session's adapter.

  The request reuses the session's selected adapter and model by default.
  Sending the conversation to a different provider requires explicit
  configuration because it changes privacy, capability, pricing, and
  provider-state assumptions.

  The call is constructed with the live system prompt, the same tool
  definitions, and the selected shadowed messages, then a final user message
  holding the compaction directive. The shared prefix is byte-identical to the
  live request so the provider can reuse its warm prompt cache. Tool schemas are
  kept present for prefix identity while `tool_choice: "none"` requests no tool
  use; a result that still contains tool calls is rejected.
  """

  @behaviour Tackle.Lib.Compaction.Summarizer

  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Usage

  @impl true
  def summarize(%Request{} = request, opts \\ []) do
    case request.selection do
      nil ->
        {:error, :missing_llm_selection}

      selection ->
        generate(selection, request, opts)
    end
  end

  defp generate(selection, %Request{} = request, opts) do
    generate_opts =
      [
        model: request.model || selection.model,
        session_id: request.session_id,
        system: request.system,
        messages: Request.to_provider_messages(request),
        temperature: 0.2,
        strict_schema: false,
        native_tools: request.tools != [],
        tools: request.tools || [],
        tool_choice: "none"
      ]
      |> maybe_put_max_tokens(request.summary_max_tokens)
      |> Kernel.++(Keyword.get(opts, :llm_opts, []))
      |> Keyword.put(:cancellation_signal, Keyword.get(opts, :cancellation_signal))

    with {:ok, response} <- LLM.generate_with(selection, nil, generate_opts) do
      build_summary(response)
    end
  end

  defp build_summary(%{data: data} = response) do
    if tool_calls?(data) do
      {:error, :summary_tool_calls}
    else
      case content(data) do
        content when is_binary(content) and content != "" ->
          {:ok,
           %Summary{
             content: content,
             usage: normalize_usage(Map.get(response, :usage)),
             model: Map.get(response, :model)
           }}

        _empty ->
          {:error, :empty_summary}
      end
    end
  end

  defp build_summary(_response), do: {:error, :invalid_summary_response}

  defp content(%{"content" => value, content: content}) when value in [nil, false], do: content
  defp content(%{"content" => content}), do: content
  defp content(%{content: content}), do: content
  defp content(_data), do: nil

  defp tool_calls?(%{"tool_calls" => value, tool_calls: calls})
       when value in [nil, false] and is_list(calls),
       do: calls != []

  defp tool_calls?(%{"tool_calls" => calls}) when is_list(calls), do: calls != []
  defp tool_calls?(%{tool_calls: calls}) when is_list(calls), do: calls != []
  defp tool_calls?(_data), do: false

  defp normalize_usage(nil), do: nil
  defp normalize_usage(usage), do: Usage.normalize(usage)

  defp maybe_put_max_tokens(opts, nil), do: opts

  defp maybe_put_max_tokens(opts, max) do
    # OpenAI-compatible adapters (DeepSeek and others) read `:max_tokens`; the
    # provider-neutral library name is `:max_output_tokens`. Set both so the
    # summary cap is honoured wherever the adapter supports a limit.
    opts
    |> Keyword.put(:max_output_tokens, max)
    |> Keyword.put(:max_tokens, max)
  end
end
