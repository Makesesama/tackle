defmodule Tackle.Runtime.AgentBackend do
  @moduledoc """
  Host adapter used by `Tackle.Runtime` to operate one concrete agent process.

  The runtime owns scopes, admission, limits, cancellation, stable
  references, and per-agent tool supervision. A backend owns the host-specific
  turn lifecycle, including persistence, authorization, billing, and event
  delivery. Backend configuration in an `AgentSpec` is trusted host data.

  `child_spec/2` receives a `Tackle.Runtime.AgentContext` containing the stable
  agent identity, coordinator, work supervisor, and dedicated tool supervisor.
  The backend process must register its live agent PID through
  `Tackle.Runtime.AgentContext.register/2` during initialization.

  The optional `services/2` callback returns per-agent service child specs,
  such as monitors that observe the agent's turns. They run under a
  `Tackle.Runtime.ServiceSupervisor` that starts after and stops before the
  backend process; a crashing service never stops the agent.
  """

  require Logger

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
          | :cancel_tool_call
          | :publish_event

  @callback validate_spec(AgentSpec.t()) :: :ok | {:error, term()}
  @callback child_spec(AgentSpec.t(), AgentContext.t()) :: Supervisor.child_spec()
  @doc """
  Performs an agent operation. `:deliver` accepts one validated
  `Tackle.Runtime.Envelope` in its argument list and synchronously reports
  acceptance or failure. Hosts without a mailbox return
  `{:error, {:unsupported_agent_operation, :deliver}}`.

  Delegated requests call `:subscribe` before `:submit` to observe progress for
  inactivity timeouts, independently of caller event callbacks. Backends must
  deliver child events to the subscribing process as `{:tackle_runtime_event,
  event}` (or the host's `{:tackle_event, session_id, turn_id, event}` form).
  Subscription failure is a request setup error.

  Backends own capacity,
  projection, and wake-up policy; they must not acknowledge dropped messages.

  `:cancel_tool_call` receives `[tool_call_id, reason]` and stops only that
  call of the agent's active turn, typically by cancelling the per-call signal
  from `Tackle.Lib.Cancellation.for_call/2` with `reason`, so the tool reports
  an error and the turn continues. Backends without per-call cancellation
  return `{:error, {:unsupported_agent_operation, :cancel_tool_call}}`.

  `:publish_event` receives `[event]`, an auxiliary `Tackle.Lib.Event`
  (`data.auxiliary == true`) from an agent service, and delivers it to the
  agent's subscribers outside any turn (the host's `{:tackle_event,
  session_id, nil, event}` form) without persisting it or treating it as
  activity. Backends without it return
  `{:error, {:unsupported_agent_operation, :publish_event}}`.
  """
  @callback call(pid(), operation(), [term()]) :: term()
  @callback prepare_child(AgentSpec.t(), pid()) :: {:ok, AgentSpec.t()} | {:error, term()}
  @doc """
  Applies a per-request model selection to a prepared child spec.

  `model` is a non-empty model reference, such as `"provider/model"`, that may
  originate from model-generated tool input. The backend must resolve it only
  against models its trusted configuration already makes available and return
  an error for anything else. Backends that do not export this callback refuse
  per-request model selection with `{:error, {:model_selection_unsupported,
  model}}`.
  """
  @callback select_model(AgentSpec.t(), String.t()) :: {:ok, AgentSpec.t()} | {:error, term()}
  @callback model_ref(AgentSpec.t()) :: String.t() | nil

  @typedoc """
  A change to a trusted spec's configuration (see `c:configure/2`):

    * `:model` - a model reference, such as `"provider/model"`, resolved like
      `c:select_model/2` against the models the configuration makes available;
    * `:thinking` - a provider-neutral thinking level
      (`Tackle.Lib.Thinking.levels/0`);
    * `:max_steps` - the most model calls one run makes;
    * `:context` - entries merged into the session context, which tools read;
    * `:llm_opts` - options merged into the adapter options, such as
      `:prompt_cache_key`.
  """
  @type configure_option ::
          {:model, String.t()}
          | {:thinking, String.t()}
          | {:max_steps, pos_integer()}
          | {:context, map()}
          | {:llm_opts, keyword()}

  @typedoc """
  What a spec's configuration runs with (see `c:describe/1`); `nil` when it
  is not set.
  """
  @type description :: %{
          model: String.t() | nil,
          thinking: String.t() | nil,
          max_steps: pos_integer() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()]
        }

  @typedoc "A model client and the options to call it with, credentials included."
  @type llm :: %{llm: term(), llm_opts: keyword()}

  @doc """
  Applies `opts` (see `t:configure_option/0`) to a trusted spec's
  configuration, in order, and returns the spec.

  Callers such as code review use it to run a profile with another model,
  thinking level, step limit, or per-run context without knowing the
  backend's configuration type. Like `c:select_model/2`, a model must
  resolve against the configuration's own providers; anything else is an
  error.
  """
  @callback configure(AgentSpec.t(), [configure_option()]) ::
              {:ok, AgentSpec.t()} | {:error, term()}

  @doc """
  Describes what a spec's configuration runs with: model reference, thinking
  level, step limit, system prompt, and tool names.
  """
  @callback describe(AgentSpec.t()) :: description()

  @doc """
  Returns the model client of a spec's configuration and the options to call
  it with directly (`Tackle.Lib.LLM`), outside an agent run, credentials
  included.
  """
  @callback llm(AgentSpec.t()) :: {:ok, llm()} | {:error, term()}
  @callback outcome(term(), AgentRef.t()) :: Outcome.t()
  @callback notify(pid(), term()) :: :ok | {:error, term()}

  @doc """
  Returns child specs for services that run beside one agent.

  Called once when the agent subtree starts, with the same context the backend
  child receives. `context.service_task_supervisor` names a `Task.Supervisor`
  that services may use for short-lived asynchronous work. Return `[]` to run
  no services; no service supervisor is started then. Services are restarted
  within a small bound and are dropped, without affecting the agent, once it
  is exceeded.

  Services are started while the agent's subtree is still starting, after the
  backend process. A service's `init/1` must stay short and must not call the
  agent's supervisors (that deadlocks), but it may call the already running
  agent, for example to subscribe before the agent's first turn begins.
  """
  @callback services(AgentSpec.t(), AgentContext.t()) :: [Supervisor.child_spec()]

  @optional_callbacks prepare_child: 2,
                      select_model: 2,
                      model_ref: 1,
                      configure: 2,
                      describe: 1,
                      llm: 1,
                      outcome: 2,
                      notify: 2,
                      services: 2

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
  def select_model(_backend, %AgentSpec{} = spec, nil), do: {:ok, spec}

  def select_model(backend, %AgentSpec{} = spec, model) do
    if function_exported?(backend, :select_model, 2) do
      backend.select_model(spec, model)
    else
      {:error, {:model_selection_unsupported, model}}
    end
  rescue
    exception -> {:error, {:agent_backend_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:agent_backend_failed, {kind, reason}}}
  end

  @doc """
  Calls a host backend operation, returning backend results unchanged.

  Raised exceptions become `{:error, {:agent_backend_failed, message}}` and
  exits become `{:error, {:agent_unavailable, reason}}`.
  """
  @spec call(module(), pid(), operation(), [term()]) :: term() | {:error, term()}
  def call(backend, pid, operation, args) do
    backend.call(pid, operation, args)
  rescue
    exception -> {:error, {:agent_backend_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:agent_unavailable, reason}}
  end

  @doc false
  @spec services(module(), AgentSpec.t(), AgentContext.t()) :: [Supervisor.child_spec()]
  def services(backend, %AgentSpec{} = spec, %AgentContext{} = context) do
    if function_exported?(backend, :services, 2) do
      case backend.services(spec, context) do
        services when is_list(services) ->
          services

        other ->
          log_services_failure(backend, context, {:invalid_services, other})
          []
      end
    else
      []
    end
  rescue
    exception ->
      log_services_failure(backend, context, Exception.message(exception))
      []
  catch
    kind, reason ->
      log_services_failure(backend, context, {kind, reason})
      []
  end

  defp log_services_failure(backend, context, reason) do
    Logger.error(
      "agent backend #{inspect(backend)} failed to provide services for " <>
        "#{inspect(context.agent_ref)}: #{inspect(reason)}; starting without services"
    )
  end

  @doc false
  def model_ref(backend, %AgentSpec{} = spec) do
    if function_exported?(backend, :model_ref, 1), do: backend.model_ref(spec)
  end

  @configure_keys [:model, :thinking, :max_steps, :context, :llm_opts]

  @doc false
  def configure(backend, %AgentSpec{} = spec, opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_configure_options, opts}}

      (unknown = Keyword.keys(opts) -- @configure_keys) != [] ->
        {:error, {:invalid_configure_options, Enum.uniq(unknown)}}

      opts == [] ->
        {:ok, spec}

      true ->
        optional(backend, :configure, [spec, opts])
    end
  end

  @doc false
  def describe(backend, %AgentSpec{} = spec) do
    case optional(backend, :describe, [spec]) do
      {:error, reason} -> {:error, reason}
      description when is_map(description) -> {:ok, description}
      other -> {:error, {:invalid_backend_description, other}}
    end
  end

  @doc false
  def llm(backend, %AgentSpec{} = spec), do: optional(backend, :llm, [spec])

  # Optional spec callbacks: an unsupported one is an error, and a failing
  # one never takes the caller down.
  defp optional(backend, name, args) do
    if function_exported?(backend, name, length(args)) do
      apply(backend, name, args)
    else
      {:error, {:unsupported_backend_callback, name}}
    end
  rescue
    exception -> {:error, {:agent_backend_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:agent_backend_failed, {kind, reason}}}
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
