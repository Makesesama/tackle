defmodule Tackle.Runtime.RootBackend do
  @moduledoc false

  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Config
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Outcome
  alias Tackle.Session

  @impl true
  def validate_spec(%AgentSpec{config: %Config{}, model_source: source})
      when source in [:configured, :parent],
      do: :ok

  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

  @impl true
  def child_spec(%AgentSpec{config: config}, %AgentContext{kind: :root} = context) do
    {Tackle.Session.RuntimeRootSupervisor, {config, context}}
  end

  def child_spec(%AgentSpec{config: config}, %AgentContext{} = context) do
    {Session, {config, session_opts(context)}}
  end

  @impl true
  def call(pid, :submit, [input]), do: Session.submit(pid, input)
  def call(pid, :continue, []), do: Session.continue(pid)
  def call(pid, :cancel, [_reason]), do: Session.cancel(pid)
  def call(pid, :subscribe, []), do: Session.subscribe(pid)
  def call(pid, :unsubscribe, []), do: Session.unsubscribe(pid)
  def call(pid, :snapshot, []), do: Session.snapshot(pid)
  def call(pid, :reconfigure, [opts]), do: Session.reconfigure(pid, opts)
  def call(pid, :abandon_turn, []), do: Session.abandon_turn(pid)
  def call(pid, :deliver, [from, message]), do: Session.deliver(pid, from, message)
  def call(pid, :compact, [opts]), do: Session.compact(pid, opts)
  def call(pid, :tree, []), do: Session.tree(pid)
  def call(pid, :navigate, [target, opts]), do: Session.navigate(pid, target, opts)
  def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}

  @impl true
  def prepare_child(%AgentSpec{model_source: :configured} = spec, _parent), do: {:ok, spec}

  def prepare_child(%AgentSpec{model_source: :parent} = spec, parent) do
    state = Session.snapshot(parent).agent_state

    with {:ok, config} <-
           Config.reconfigure(spec.config,
             model: state.llm.ref,
             thinking: Tackle.Thinking.from_llm_opts(state.llm_opts)
           ) do
      {:ok, %{spec | config: config}}
    end
  end

  @impl true
  def model_ref(%AgentSpec{config: %Config{model_ref: model_ref}}), do: model_ref

  @impl true
  def outcome(%Outcome{} = outcome, _agent_ref), do: outcome

  def outcome({status, state}, agent_ref) when status in [:ok, :error, :cancelled] do
    Outcome.new(status, agent_state: state, agent_ref: agent_ref)
  end

  def outcome(other, agent_ref) do
    Outcome.new(:runtime_error, reason: {:unexpected_backend_result, other}, agent_ref: agent_ref)
  end

  @impl true
  def notify(pid, {:background_started, run_ref, origin, message}) do
    Session.background_started(pid, run_ref, origin, message)
  end

  def notify(pid, {:background_finished, run_ref, profile, outcome, message}) do
    Session.background_finished(pid, run_ref, profile, outcome, message)
  end

  def notify(_pid, _notification), do: :ok

  @doc false
  def session_opts(%AgentContext{} = context) do
    [
      scope_ref: context.scope_ref,
      agent_ref: context.agent_ref,
      lifetime: context.lifetime,
      allow_delegation: context.allow_delegation,
      limits: context.limits,
      coordinator: context.coordinator,
      work_supervisor: context.work_supervisor,
      tool_supervisor: context.tool_supervisor,
      parent: context.parent,
      context_overrides: event_context(context),
      terminal: context.terminal,
      id: {:session, context.agent_ref.agent_id},
      restart: :permanent
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp event_context(%AgentContext{event_callback: callback}) when is_function(callback, 1),
    do: %{event_callback: callback}

  defp event_context(_context), do: %{}
end
