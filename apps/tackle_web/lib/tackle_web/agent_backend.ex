defmodule Tackle.Web.AgentBackend do
  @moduledoc """
  Ephemeral review agents on `Tackle.Runtime`, without the local harness.

  Build trusted specs with `config/1`, using providers from
  `Tackle.Web.Models.enabled_providers/1` of one owner. Every spec carries
  that owner's stable database credential-store handle. The host supplies tools and executor context; this
  backend neither chooses an executor nor persists conversations.

  Each agent owns one linked turn task at a time. Events go to monitored
  subscribers and delegated outcomes to the runtime. Stopping the agent stops
  its turn even when an adapter ignores cooperative cancellation.
  """

  @behaviour Tackle.Runtime.AgentBackend
  use GenServer, restart: :temporary

  alias Tackle.Lib.{Cancellation, LLM, State, Thinking}
  alias Tackle.Runtime.{AgentContext, AgentSpec, Outcome}
  alias Tackle.Web.CredentialStore

  defmodule Config do
    @moduledoc "Trusted, in-memory configuration of a review agent."
    @enforce_keys [:providers, :model_ref, :llm, :credential_store]
    defstruct [
      :providers,
      :credential_store,
      :model_ref,
      :llm,
      tools: [],
      system_prompt: "",
      context: %{},
      llm_opts: [],
      max_steps: nil
    ]

    @type t :: %__MODULE__{
            providers: [Tackle.Lib.LLM.Provider.source()],
            credential_store: Tackle.Lib.CredentialStore.handle(),
            model_ref: String.t(),
            llm: term(),
            tools: [module()],
            system_prompt: String.t(),
            context: map(),
            llm_opts: keyword(),
            max_steps: pos_integer() | nil
          }
  end

  @doc """
  Builds a configuration from `:providers`, `:owner_id` (the user the
  providers belong to), `:model`, and optionally `:tools`, `:system_prompt`,
  `:context`, `:llm_opts`, `:thinking`, and `:max_steps`. The model must
  resolve against the supplied providers; there is no implicit model.
  Adapter options always use the owner's database store
  (`Tackle.Web.CredentialStore.handle/1`).
  """
  @spec config(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def config(opts) do
    providers = Keyword.fetch!(opts, :providers)
    store = CredentialStore.handle(Keyword.fetch!(opts, :owner_id))

    with {:ok, llm} <- LLM.select(providers, Keyword.fetch!(opts, :model)),
         {:ok, llm_opts} <-
           thinking(Keyword.get(opts, :llm_opts, []), Keyword.get(opts, :thinking)) do
      config = %Config{
        providers: providers,
        credential_store: store,
        model_ref: llm.ref,
        llm: llm,
        tools: Keyword.get(opts, :tools, []),
        system_prompt: Keyword.get(opts, :system_prompt, ""),
        context: Keyword.get(opts, :context, %{}),
        llm_opts: Keyword.put(llm_opts, :credential_store, store),
        max_steps: Keyword.get(opts, :max_steps)
      }

      with :ok <- validate_config(config), do: {:ok, config}
    end
  end

  defp thinking(llm_opts, nil), do: {:ok, llm_opts}
  defp thinking(llm_opts, level), do: Thinking.put_llm_opts(llm_opts, level)

  ## Spec callbacks

  @impl true
  def validate_spec(%AgentSpec{config: %Config{} = config}), do: validate_config(config)
  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

  defp validate_config(config) do
    cond do
      not is_map(config.context) -> {:error, :invalid_agent_context}
      not Keyword.keyword?(config.llm_opts) -> {:error, :invalid_llm_opts}
      not is_list(config.tools) -> {:error, :invalid_tools}
      not is_binary(config.system_prompt) -> {:error, :invalid_system_prompt}
      not valid_steps?(config.max_steps) -> {:error, :invalid_max_steps}
      true -> :ok
    end
  end

  defp valid_steps?(nil), do: true
  defp valid_steps?(steps), do: is_integer(steps) and steps > 0

  @impl true
  def child_spec(spec, context), do: {__MODULE__, {spec, context}}

  @impl true
  def prepare_child(%AgentSpec{model_source: :parent} = spec, parent) do
    %{agent_state: %State{llm: llm, llm_opts: llm_opts}} = GenServer.call(parent, {:snapshot, []})
    configure(spec, model: llm.ref, thinking: Thinking.from_llm_opts(llm_opts))
  end

  def prepare_child(spec, _parent), do: {:ok, spec}

  @impl true
  def select_model(spec, model), do: configure(spec, model: model)

  @impl true
  def model_ref(%AgentSpec{config: %Config{model_ref: ref}}), do: ref

  @impl true
  def configure(%AgentSpec{config: %Config{} = config} = spec, opts) do
    Enum.reduce_while(opts, {:ok, config}, fn option, {:ok, config} ->
      case configure_option(config, option) do
        {:ok, config} -> {:cont, {:ok, config}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, config} ->
        with :ok <- validate_config(config), do: {:ok, %{spec | config: config}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_option(config, {:model, model}) do
    with {:ok, llm} <- LLM.select(config.providers, model) do
      {:ok, %{config | llm: llm, model_ref: llm.ref}}
    end
  end

  defp configure_option(config, {:thinking, level}) do
    with {:ok, llm_opts} <- Thinking.put_llm_opts(config.llm_opts, level) do
      {:ok, %{config | llm_opts: llm_opts}}
    end
  end

  defp configure_option(config, {:max_steps, steps}), do: {:ok, %{config | max_steps: steps}}

  defp configure_option(config, {:context, context}) when is_map(context),
    do: {:ok, %{config | context: Map.merge(config.context, context)}}

  defp configure_option(config, {:llm_opts, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      llm_opts =
        config.llm_opts
        |> Keyword.merge(opts)
        |> Keyword.put(:credential_store, config.credential_store)

      {:ok, %{config | llm_opts: llm_opts}}
    else
      {:error, :invalid_llm_opts}
    end
  end

  defp configure_option(_config, {key, _value}), do: {:error, {:invalid_agent_option, key}}

  @impl true
  def describe(%AgentSpec{config: %Config{} = config}) do
    %{
      model: config.model_ref,
      thinking: Thinking.from_llm_opts(config.llm_opts),
      max_steps: config.max_steps,
      system_prompt: config.system_prompt,
      tools: Enum.map(config.tools, & &1.name())
    }
  end

  @impl true
  def llm(%AgentSpec{config: %Config{llm: llm, llm_opts: llm_opts}}),
    do: {:ok, %{llm: llm, llm_opts: llm_opts}}

  @impl true
  def outcome(%Outcome{} = outcome, _agent_ref), do: outcome

  def outcome({status, %State{} = state}, agent_ref) when status in [:ok, :error, :cancelled],
    do: Outcome.new(status, agent_state: state, agent_ref: agent_ref)

  ## Agent process

  @doc false
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def call(pid, operation, args), do: GenServer.call(pid, {operation, args})

  @impl true
  def init({%AgentSpec{config: %Config{} = config}, %AgentContext{} = context}) do
    Process.flag(:trap_exit, true)
    :ok = AgentContext.register(context)

    agent_state =
      Tackle.Lib.new(
        llm: config.llm,
        tools: config.tools,
        system_prompt: config.system_prompt,
        context: Map.put(config.context, :runtime, context.agent_ref),
        max_iterations: config.max_steps || :infinity,
        llm_opts: config.llm_opts
      )

    {:ok,
     %{
       config: config,
       context: context,
       agent_state: agent_state,
       subscribers: %{},
       task: nil,
       signal: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, []}, {pid, _tag}, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, %{}}, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, []}, {pid, _tag}, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:snapshot, []}, _from, state),
    do: {:reply, %{agent_state: state.agent_state}, state}

  def handle_call({:submit, [prompt]}, _from, %{task: nil} = state) do
    server = self()
    signal = Cancellation.new_signal()
    agent_state = state.agent_state
    tool_supervisor = state.context.tool_supervisor
    turn_id = "turn-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        Tackle.Lib.run(agent_state, prompt,
          event_callback: &send(server, {:lib_event, &1}),
          cancellation_signal: signal,
          tool_supervisor: tool_supervisor,
          turn_id: turn_id,
          llm_stream: true
        )
      end)

    {:reply, {:ok, turn_id}, %{state | task: task, signal: signal}}
  end

  def handle_call({:submit, [_prompt]}, _from, state), do: {:reply, {:error, :busy}, state}

  # Changes an idle agent's model or thinking level, as a session's `/model`.
  def handle_call({:reconfigure, [opts]}, _from, %{task: nil} = state) do
    spec = %AgentSpec{name: "agent", config: state.config}

    case configure(spec, Keyword.take(opts, [:model, :thinking])) do
      {:ok, %AgentSpec{config: config}} ->
        agent_state = %{state.agent_state | llm: config.llm, llm_opts: config.llm_opts}
        state = %{state | config: config, agent_state: agent_state}
        {:reply, {:ok, %{agent_state: agent_state}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconfigure, [_opts]}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:cancel, [reason]}, _from, state), do: {:reply, :ok, cancel(state, reason)}

  def handle_call({operation, _args}, _from, state),
    do: {:reply, {:error, {:unsupported_agent_operation, operation}}, state}

  @impl true
  def handle_info({:lib_event, event}, state) do
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:tackle_runtime_event, event}) end)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {_status, agent_state} = result
    finish(result, %{state | task: nil, agent_state: agent_state})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    outcome =
      Outcome.new(:runtime_error, reason: reason, agent_ref: state.context.agent_ref)

    finish(outcome, %{state | task: nil})
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      if Map.get(state.subscribers, pid) == ref,
        do: Map.delete(state.subscribers, pid),
        else: state.subscribers

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:runtime_cancel, reason}, state), do: {:noreply, cancel(state, reason)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel(state, :agent_stopped)
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    Cancellation.delete(state.signal)
    :ok
  end

  defp cancel(%{signal: nil} = state, _reason), do: state

  defp cancel(%{signal: signal} = state, reason) do
    Cancellation.cancel(signal, reason)
    state
  end

  # A delegated run reports its outcome; the root agent has nobody to tell.
  defp finish(result, state) do
    Cancellation.delete(state.signal)

    if terminal = state.context.terminal do
      send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, result})
    end

    {:noreply, %{state | signal: nil}}
  end
end
