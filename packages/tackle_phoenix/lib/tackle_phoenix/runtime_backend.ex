defmodule Tackle.Phoenix.RuntimeBackend do
  @moduledoc """
  `Tackle.Runtime.AgentBackend` adapter for `Tackle.Phoenix.Runner`.

  Runtime-owned agents still execute the complete Runner/Store lifecycle. No
  delegated turn bypasses the host's authorization, quota, persistence,
  settlement, billing, telemetry, or PubSub callbacks.
  """

  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Lib.State
  alias Tackle.Phoenix.Runner
  alias Tackle.Phoenix.RuntimeSpec
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Outcome

  @impl true
  def validate_spec(%AgentSpec{config: %RuntimeSpec{} = config}) do
    case RuntimeSpec.new(config) do
      {:ok, _spec} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

  @impl true
  def child_spec(%AgentSpec{config: %RuntimeSpec{} = spec}, %AgentContext{} = context) do
    session_id = spec.session_id || context.agent_ref.agent_id

    runner =
      spec.runner
      |> Map.put(:tool_supervisor, context.tool_supervisor)
      |> Map.put(:runtime_context, context)
      |> Map.put(:runtime_turn_opts, spec.turn_opts)

    {Runner, {runner, spec.user_id, session_id, spec.agent_state, spec.host_state}}
  end

  @impl true
  def call(pid, :submit, [input]) when is_binary(input), do: Runner.runtime_submit(pid, input)
  def call(_pid, :submit, [input]), do: {:error, {:invalid_input, input}}
  def call(pid, :continue, []), do: Runner.runtime_continue(pid)
  def call(pid, :cancel, [reason]), do: Runner.cancel_turn(pid, reason)
  def call(pid, :subscribe, []), do: Runner.runtime_subscribe(pid, self())
  def call(pid, :unsubscribe, []), do: Runner.runtime_unsubscribe(pid, self())
  def call(pid, :snapshot, []), do: Runner.snapshot(pid)

  def call(_pid, :deliver, [_envelope]),
    do: {:error, {:unsupported_agent_operation, :deliver}}

  def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}

  @impl true
  def model_ref(%AgentSpec{config: %RuntimeSpec{agent_state: %State{llm: nil}}}), do: nil

  def model_ref(%AgentSpec{config: %RuntimeSpec{agent_state: %State{llm: llm}}}) do
    Map.get(llm, :ref)
  end

  @impl true
  def outcome({status, %State{} = state}, %AgentRef{} = agent_ref)
      when status in [:ok, :error, :cancelled] do
    Outcome.new(status, agent_state: state, agent_ref: agent_ref)
  end

  def outcome({:runtime_error, reason}, %AgentRef{} = agent_ref) do
    Outcome.new(:runtime_error, reason: reason, agent_ref: agent_ref)
  end

  def outcome(other, %AgentRef{} = agent_ref) do
    Outcome.new(:runtime_error, reason: {:unexpected_backend_result, other}, agent_ref: agent_ref)
  end

  @impl true
  def notify(pid, notification) do
    send(pid, {:tackle_runtime_notification, notification})
    :ok
  end
end
