defmodule Tackle.Runtime.AgentBackend do
  @moduledoc """
  Host adapter used by `Tackle.Runtime` to operate one concrete agent process.

  The runtime owns scopes, admission, limits, cancellation, workflows, stable
  references, and per-agent tool supervision. A backend owns the host-specific
  turn lifecycle, including persistence, authorization, billing, and event
  delivery. Backend configuration in an `AgentSpec` is trusted host data.

  `child_spec/2` receives a `Tackle.Runtime.AgentContext` containing the stable
  agent identity, coordinator, work supervisor, and dedicated tool supervisor.
  The backend process must register its live agent PID through
  `Tackle.Runtime.AgentContext.register/2` during initialization.
  """

  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Outcome

  @type operation ::
          :submit
          | :continue
          | :cancel
          | :subscribe
          | :unsubscribe
          | :snapshot
          | :reconfigure
          | :abandon_turn
          | :deliver
          | :compact
          | :tree
          | :navigate

  @callback validate_spec(AgentSpec.t()) :: :ok | {:error, term()}
  @callback child_spec(AgentSpec.t(), AgentContext.t()) :: Supervisor.child_spec()
  @callback call(pid(), operation(), [term()]) :: term()
  @callback prepare_child(AgentSpec.t(), pid()) :: {:ok, AgentSpec.t()} | {:error, term()}
  @callback model_ref(AgentSpec.t()) :: String.t() | nil
  @callback outcome(term(), AgentRef.t()) :: Outcome.t()
  @callback notify(pid(), term()) :: :ok | {:error, term()}

  @optional_callbacks prepare_child: 2, model_ref: 1, outcome: 2, notify: 2

  @doc false
  def validate_spec(backend, %AgentSpec{} = spec) when is_atom(backend) do
    with :ok <- validate_module(backend) do
      backend.validate_spec(spec)
    end
  end

  @doc false
  def prepare_child(backend, %AgentSpec{} = spec, parent) do
    if function_exported?(backend, :prepare_child, 2) do
      backend.prepare_child(spec, parent)
    else
      {:ok, spec}
    end
  rescue
    exception -> {:error, {:agent_backend_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:agent_backend_failed, {kind, reason}}}
  end

  @doc false
  def model_ref(backend, %AgentSpec{} = spec) do
    if function_exported?(backend, :model_ref, 1), do: backend.model_ref(spec)
  end

  @doc false
  def outcome(_backend, %Outcome{} = outcome, _agent_ref), do: outcome

  def outcome(backend, result, %AgentRef{} = agent_ref) do
    if function_exported?(backend, :outcome, 2) do
      backend.outcome(result, agent_ref)
    else
      Outcome.new(:runtime_error,
        reason: {:invalid_backend_outcome, result},
        agent_ref: agent_ref
      )
    end
  end

  @doc false
  def notify(backend, pid, notification) do
    if function_exported?(backend, :notify, 2) do
      backend.notify(pid, notification)
    else
      :ok
    end
  end

  defp validate_module(backend) do
    case Code.ensure_loaded(backend) do
      {:module, ^backend} ->
        if exports_required_functions?(backend) do
          :ok
        else
          {:error, {:invalid_agent_backend, backend}}
        end

      {:error, reason} ->
        {:error, {:agent_backend_unavailable, backend, reason}}
    end
  end

  defp exports_required_functions?(backend) do
    required = [validate_spec: 1, child_spec: 2, call: 3]

    Enum.all?(required, fn {name, arity} -> function_exported?(backend, name, arity) end)
  end
end
