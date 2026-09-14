defmodule Tackle.CLI.TUI.Diagnostics do
  @moduledoc """
  Read-only projections for the Browse pages. No
  provider calls, credential reads, persistence, or global telemetry handlers.
  """

  alias Tackle.CLI.TUI.State
  alias Tackle.Lib.{ContextUsage, Usage}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Tool.Registry

  @doc "Produces an explicit, provider-neutral diagnostic projection for local inspection."
  @spec text(State.t(), atom()) :: String.t()
  def text(state, page) do
    "Browse / #{page} — snapshot at #{DateTime.to_iso8601(DateTime.utc_now())}\n" <>
      "←/→ or Tab page · R refresh · Y copy page · Esc/F4 back\n" <>
      "Local inspection only. Prompt/context may contain private workspace text.\n" <>
      "Credentials, arbitrary adapter options, raw metadata and provider continuation state are omitted.\n" <>
      "nil means unavailable/not applicable, not zero.\n\n" <> body(state, page)
  end

  defp body(%State{agent_state: nil}, page) when page != :events,
    do: "Agent snapshot unavailable."

  defp body(state, :overview) do
    agent = state.agent_state

    dump(%{
      session_id: state.session_id,
      active_turn_id: state.active_turn && state.active_turn.id,
      pending_operation: state.pending_operation && state.pending_operation.kind,
      activity: state.activity,
      outcome: state.outcome,
      settled_status: agent.status,
      model: State.model_ref(agent),
      model_info: State.model_info(agent),
      thinking: Tackle.Thinking.from_llm_opts(agent.llm_opts),
      settled_iteration: agent.current_iteration,
      max_iterations: agent.max_iterations,
      retry: agent.retry,
      compaction: compaction_policy(agent.compaction),
      tool_policy: agent.tool_policy,
      hooks: agent.hooks,
      prompt_renderer: agent.prompt_renderer,
      transcript_messages: length(agent.messages),
      model_context_messages: length(AgentState.model_messages(agent)),
      last_compaction_id: AgentState.last_compaction_id(agent),
      archive_usage: usage(AgentState.usage(agent)),
      active_branch_usage: usage(AgentState.branch_usage(agent)),
      live_turn_usage: usage(Usage.aggregate(state.metrics.turn_usages)),
      latest_usage: usage(state.metrics.latest_usage || State.latest_usage(agent)),
      context_pressure: state.metrics.context_usage || ContextUsage.estimate(agent)
    }) <>
      "\n\nArchive/branch totals are settled; live turn usage is separate, not additive after settlement.\n" <>
      "Context pressure may be estimated; this is not an exact provider request capture."
  end

  defp body(state, :subagents) do
    "Live delegated sessions in this scope. This page updates while open.\n" <>
      "Child conversation text can be inspected while the child is running; credentials, raw adapter options, and opaque provider state are omitted.\n\n" <>
      case state.subagents |> Map.values() |> Enum.sort_by(&Map.get(&1, :started_at_ms, 0)) do
        [] ->
          "No subagents observed for this turn."

        subagents ->
          Enum.map_join(subagents, "\n\n", &subagent_dump/1)
      end
  end

  defp body(state, :prompt) do
    "Configured composed system prompt (not a capture of hook/adapter transformations):\n\n" <>
      (state.agent_state.system_prompt || "System prompt unavailable.")
  end

  defp body(state, :context) do
    messages = AgentState.model_messages(state.agent_state)

    "Last settled model-context projection; active-turn additions may not be present.\n" <>
      "Compactions apply here; F4 shows the active transcript, F5 the tree.\n" <>
      "Multimodal payloads are not displayed; retained part counts are shown.\n\n" <>
      if messages == [] do
        "No settled context messages."
      else
        Enum.map_join(messages, "\n\n", fn message ->
          dump(%{
            id: message.id,
            role: message.role,
            timestamp: message.timestamp,
            model: message.model,
            usage: usage(message.token_usage),
            tool_call_id: message.tool_call_id,
            tool_name: message.tool_name,
            tool_calls: message.tool_calls,
            retained_parts: length(message.parts || []),
            content: message.content,
            thinking: message.thinking
          })
        end)
      end
  end

  defp body(state, :tools) do
    "Registered provider-neutral definitions (before any per-turn hook changes):\n\n" <>
      dump(Registry.definitions(state.agent_state.tool_registry) |> Enum.sort_by(& &1.name))
  end

  defp body(state, :events) do
    observations = state.observations

    "Events observed by this UI attachment only; not replayed from durable history.\n" <>
      "Newest 500 lifecycle events retained; #{observations.dropped} older events dropped.\n" <>
      "#{observations.deltas} streaming deltas counted, payloads omitted.\n" <>
      "elapsed_ms is local monotonic time since the first observation, not provider latency.\n" <>
      "Event details are allowlisted and strings capped at 200 characters. Error bodies, tool I/O, raw payloads omitted.\n\n" <>
      if observations.events == [] do
        "No lifecycle events observed yet."
      else
        observations.events |> Enum.reverse() |> Enum.map_join("\n\n", &dump/1)
      end
  end

  defp subagent_dump(subagent) do
    live = live_subagent(subagent)

    dump(%{
      run_id: subagent.run_id,
      agent_id: subagent.agent_ref && subagent.agent_ref.agent_id,
      profile: subagent.profile,
      status: live.status,
      active_turn_id: live.active_turn_id,
      model: live.model,
      thinking: live.thinking,
      iteration: live.iteration,
      max_iterations: live.max_iterations,
      messages: live.messages,
      error: live.error
    })
  end

  defp live_subagent(%{status: status}) when status not in [:running, :completed] do
    Map.merge(empty_subagent(), %{status: status})
  end

  defp live_subagent(%{status: :completed}) do
    Map.merge(empty_subagent(), %{status: :completed})
  end

  defp live_subagent(subagent) do
    with {:ok, snapshot} <- Tackle.Runtime.session_snapshot(subagent.agent_ref) do
      agent = snapshot.agent_state

      %{
        status: live_status(agent, snapshot),
        active_turn_id: snapshot.active_turn && snapshot.active_turn.id,
        model: State.model_ref(agent),
        thinking: Tackle.Thinking.from_llm_opts(agent.llm_opts),
        iteration: agent.current_iteration,
        max_iterations: agent.max_iterations,
        messages: Enum.map(agent.messages, &subagent_message/1),
        error: agent.error
      }
    else
      {:error, reason} -> Map.merge(empty_subagent(), %{status: :unavailable, error: reason})
    end
  end

  defp live_status(_agent, %{active_turn: %{} = _turn}), do: :running
  defp live_status(agent, _snapshot), do: agent.status

  defp empty_subagent do
    %{
      status: nil,
      active_turn_id: nil,
      model: nil,
      thinking: nil,
      iteration: nil,
      max_iterations: nil,
      messages: [],
      error: nil
    }
  end

  defp subagent_message(message) do
    %{
      id: message.id,
      role: message.role,
      tool_call_id: message.tool_call_id,
      tool_name: message.tool_name,
      tool_calls: message.tool_calls,
      content: message.content,
      thinking: message.thinking
    }
  end

  defp compaction_policy(nil), do: nil

  defp compaction_policy(config),
    do: Map.take(config, [:enabled?, :policy, :summarizer, :committer, :max_passes])

  defp usage(nil), do: nil
  defp usage(value), do: value |> Usage.normalize() |> Map.from_struct() |> Map.delete(:raw)

  defp dump(value),
    do:
      inspect(value,
        pretty: true,
        width: 90,
        limit: :infinity,
        printable_limit: :infinity,
        sort_maps: true
      )
end
