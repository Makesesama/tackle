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

  ## Output limit and reasoning

  The request asks for at most the policy's `summary_max_tokens` output
  tokens (`:max_tokens`; an adapter whose provider refuses an output limit,
  such as Codex, ignores it) and the response's `:stop_reason` is passed on
  so the core can tell a cut-off summary from a complete one.

  It also asks for the `"minimal"` thinking level (`:reasoning_effort`),
  whatever the session uses, and each adapter sends the nearest level its
  model supports. Summarizing is recall and compression, not problem
  solving: reasoning tokens add cost and latency without improving the
  checkpoint, and providers that count reasoning against the output limit
  (Anthropic's thinking budget is part of `max_tokens`) would otherwise leave
  little room for the summary itself. The trade-off is that a provider which
  keys its prompt cache on thinking settings may not reuse the live request's
  cache for this one call.
  """

  @behaviour Tackle.Lib.Compaction.Summarizer

  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Response

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
    request_opts =
      [
        model: request.model || selection.model,
        session_id: request.session_id,
        system: request.system,
        messages: Request.to_provider_messages(request),
        tools: request.tools || [],
        tool_choice: "none",
        reasoning_effort: "minimal",
        cancellation_signal: Keyword.get(opts, :cancellation_signal)
      ]
      |> maybe_put_max_tokens(request.summary_max_tokens)

    generate_opts =
      LLM.request_opts(request_opts, [temperature: 0.2], Keyword.get(opts, :llm_opts, []))

    with {:ok, response} <- LLM.generate_with(selection, nil, generate_opts) do
      build_summary(response)
    end
  end

  defp build_summary(%Response{tool_calls: [_ | _]}), do: {:error, :summary_tool_calls}

  defp build_summary(%Response{content: content} = response)
       when is_binary(content) and content != "" do
    {:ok,
     %Summary{
       content: content,
       usage: response.usage,
       model: response.model,
       stop_reason: response.stop_reason
     }}
  end

  defp build_summary(%Response{}), do: {:error, :empty_summary}

  defp maybe_put_max_tokens(opts, nil), do: opts
  defp maybe_put_max_tokens(opts, max), do: Keyword.put(opts, :max_tokens, max)
end
