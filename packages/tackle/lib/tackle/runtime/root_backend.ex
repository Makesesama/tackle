defmodule Tackle.Runtime.RootBackend do
  @moduledoc false

  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Lib.Thinking
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
    {Session, {config, context, nil}}
  end

  @impl true
  def call(pid, :submit, [input]), do: Session.submit(pid, input)
  def call(pid, :withdraw_queued, [content]), do: Session.withdraw_queued(pid, content)
  def call(pid, :continue, []), do: Session.continue(pid)
  def call(pid, :cancel, [reason]), do: Session.cancel(pid, reason)

  def call(pid, :cancel_tool_call, [tool_call_id, reason]),
    do: Session.cancel_tool_call(pid, tool_call_id, reason)

  def call(pid, :publish_event, [event]), do: Session.publish_event(pid, event)
  def call(pid, :subscribe, []), do: Session.subscribe(pid)
  def call(pid, :unsubscribe, []), do: Session.unsubscribe(pid)
  def call(pid, :snapshot, []), do: Session.snapshot(pid)
  def call(pid, :reconfigure, [opts]), do: Session.reconfigure(pid, opts)
  def call(pid, :abandon_turn, []), do: Session.abandon_turn(pid)
  def call(pid, :deliver, [envelope]), do: Session.deliver(pid, envelope)
  def call(pid, :compact, [opts]), do: Session.compact(pid, opts)
  def call(pid, :navigate, [target, opts]), do: Session.navigate(pid, target, opts)
  def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}

  # Every session whose config enables the watchdog (root, subagent, or
  # workflow child) gets its own, beside its session. The narrator runs only
  # beside the root session: it observes delegated runs through the progress
  # the root forwards, so one narrator serves the whole scope.
  @impl true
  def services(%AgentSpec{config: %Config{} = config}, %AgentContext{} = context) do
    watchdog_service(config, context) ++ narrator_service(config, context)
  end

  def services(%AgentSpec{}, %AgentContext{}), do: []

  # Selections carry their provider's settings, so the services need no
  # session options to reach their models.
  defp watchdog_service(%Config{watchdog: %Tackle.Config.Watchdog{} = settings}, context) do
    [
      {Tackle.Watchdog,
       agent_ref: context.agent_ref,
       task_supervisor: context.service_task_supervisor,
       settings: settings}
    ]
  end

  defp watchdog_service(_config, _context), do: []

  defp narrator_service(
         %Config{narration: %Tackle.Config.Narration{} = settings},
         %AgentContext{kind: :root, parent: nil} = context
       ) do
    [
      {Tackle.Narrator,
       agent_ref: context.agent_ref,
       task_supervisor: context.service_task_supervisor,
       settings: settings}
    ]
  end

  defp narrator_service(_config, _context), do: []

  @impl true
  def prepare_child(%AgentSpec{model_source: :configured} = spec, _parent), do: {:ok, spec}

  def prepare_child(%AgentSpec{model_source: :parent} = spec, parent) do
    with {:ok, config} <- inherit_model(spec.config, Session.snapshot(parent).agent_state) do
      {:ok, %{spec | config: config}}
    end
  end

  # A `model_source: :parent` child runs on its parent's current model and
  # thinking level.
  defp inherit_model(%Config{} = config, %Tackle.Lib.State{llm: llm, llm_opts: llm_opts}) do
    Config.update(config, model: llm.ref, thinking: Thinking.from_llm_opts(llm_opts))
  end

  @impl true
  def select_model(%AgentSpec{config: %Config{} = config} = spec, model) do
    with {:ok, config} <- Config.update(config, model: model) do
      {:ok, %{spec | config: config}}
    end
  end

  @impl true
  def model_ref(%AgentSpec{config: %Config{model_ref: model_ref}}), do: model_ref

  # Each option goes through `Tackle.Config.update/2`, which checks it as
  # `Tackle.Config.new/1` would; models resolve against the configuration's own
  # providers, as for a session's `/model`.
  @impl true
  def configure(%AgentSpec{config: %Config{} = config} = spec, opts) do
    opts
    |> Enum.reduce_while({:ok, config}, fn option, {:ok, config} ->
      case configure_option(config, option) do
        {:ok, config} -> {:cont, {:ok, config}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, config} -> {:ok, %{spec | config: config}}
      {:error, reason} -> {:error, reason}
    end
  end

  def configure(%AgentSpec{config: config}, _opts), do: {:error, {:invalid_agent_config, config}}

  defp configure_option(config, {:max_steps, steps}) when is_integer(steps) and steps > 0,
    do: Config.update(config, max_iterations: steps)

  defp configure_option(_config, {:max_steps, steps}),
    do: {:error, {:invalid_option, :max_steps, steps}}

  defp configure_option(config, {key, value})
       when key in [:model, :thinking, :context, :llm_opts],
       do: Config.update(config, [{key, value}])

  defp configure_option(_config, {key, value}), do: {:error, {:invalid_option, key, value}}

  @impl true
  def describe(%AgentSpec{config: %Config{} = config}) do
    %{
      model: config.model_ref,
      thinking: Thinking.from_llm_opts(config.llm_opts),
      max_steps: if(is_integer(config.max_iterations), do: config.max_iterations),
      system_prompt: config.system_prompt,
      tools: Enum.map(config.tools, & &1.name())
    }
  end

  # A direct model call outside a session reads credentials from the same
  # store sessions use.
  @impl true
  def llm(%AgentSpec{config: %Config{llm: llm, llm_opts: llm_opts}}) do
    {:ok,
     %{llm: llm, llm_opts: Keyword.put(llm_opts, :credential_store, Auth.credential_store())}}
  end

  def llm(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

  @impl true
  def outcome(%Outcome{} = outcome, _agent_ref), do: outcome

  def outcome({status, state}, agent_ref) when status in [:ok, :error, :cancelled] do
    Outcome.new(status, agent_state: state, agent_ref: agent_ref)
  end

  def outcome(other, agent_ref) do
    Outcome.new(:runtime_error, reason: {:unexpected_backend_result, other}, agent_ref: agent_ref)
  end

  @impl true
  def notify(pid, {:background_finished, run_ref, profile, outcome}) do
    Session.background_finished(pid, run_ref, profile, outcome)
  end

  def notify(_pid, _notification), do: :ok
end
