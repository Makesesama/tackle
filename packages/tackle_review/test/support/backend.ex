defmodule Tackle.Review.Test.Backend do
  @moduledoc false
  # The smallest host code review needs: a `Tackle.Runtime.AgentBackend` that
  # runs `Tackle.Lib` loops directly, without the harness. Its configuration
  # is a `Config` built with `config/1`. Each agent is a process that runs one
  # turn at a time in a task, forwards the loop's events to its subscribers,
  # and reports a delegated run's outcome to the runtime.

  @behaviour Tackle.Runtime.AgentBackend
  use GenServer, restart: :temporary

  alias Tackle.Lib.{Cancellation, LLM, State, Thinking}
  alias Tackle.Runtime.{AgentContext, AgentSpec, Outcome}

  defmodule Config do
    @moduledoc false
    @enforce_keys [:providers, :model_ref, :llm]
    defstruct [
      :providers,
      :model_ref,
      :llm,
      tools: [],
      system_prompt: "",
      context: %{},
      llm_opts: [],
      max_steps: nil
    ]
  end

  @doc """
  Builds a configuration from `:providers`, `:model`, and optionally
  `:tools`, `:system_prompt`, `:context`, `:llm_opts`, `:thinking`, and
  `:max_iterations`.
  """
  def config(opts) do
    providers = Keyword.fetch!(opts, :providers)

    with {:ok, llm} <- LLM.select(providers, Keyword.fetch!(opts, :model)),
         {:ok, llm_opts} <-
           thinking(Keyword.get(opts, :llm_opts, []), Keyword.get(opts, :thinking)) do
      {:ok,
       %Config{
         providers: providers,
         model_ref: llm.ref,
         llm: llm,
         tools: Keyword.get(opts, :tools, []),
         system_prompt: Keyword.get(opts, :system_prompt, ""),
         context: Keyword.get(opts, :context, %{}),
         llm_opts: llm_opts,
         max_steps: Keyword.get(opts, :max_iterations)
       }}
    end
  end

  defp thinking(llm_opts, nil), do: {:ok, llm_opts}
  defp thinking(llm_opts, level), do: Thinking.put_llm_opts(llm_opts, level)

  ## Spec callbacks

  @impl true
  def validate_spec(%AgentSpec{config: %Config{}}), do: :ok
  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

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
      {:ok, config} -> {:ok, %{spec | config: config}}
      {:error, reason} -> {:error, reason}
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

  defp configure_option(config, {:context, context}),
    do: {:ok, %{config | context: Map.merge(config.context, context)}}

  defp configure_option(config, {:llm_opts, opts}),
    do: {:ok, %{config | llm_opts: Keyword.merge(config.llm_opts, opts)}}

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

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def call(pid, operation, args), do: GenServer.call(pid, {operation, args})

  @impl true
  def init({%AgentSpec{config: %Config{} = config}, %AgentContext{} = context}) do
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
       subscribers: [],
       task: nil,
       signal: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, []}, {pid, _tag}, state),
    do: {:reply, {:ok, %{}}, %{state | subscribers: [pid | state.subscribers]}}

  def handle_call({:snapshot, []}, _from, state),
    do: {:reply, %{agent_state: state.agent_state}, state}

  def handle_call({:submit, [prompt]}, _from, %{task: nil} = state) do
    server = self()
    signal = Cancellation.new_signal()
    agent_state = state.agent_state

    task =
      Task.async(fn ->
        Tackle.Lib.run(agent_state, prompt,
          event_callback: &send(server, {:lib_event, &1}),
          cancellation_signal: signal
        )
      end)

    {:reply, {:ok, "turn-#{System.unique_integer([:positive])}"},
     %{state | task: task, signal: signal}}
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

  def handle_call({:cancel, [reason]}, _from, state), do: {:reply, :ok, cancel(state, reason)}

  def handle_call({operation, _args}, _from, state),
    do: {:reply, {:error, {:unsupported_agent_operation, operation}}, state}

  @impl true
  def handle_info({:lib_event, event}, state) do
    Enum.each(state.subscribers, &send(&1, {:tackle_runtime_event, event}))
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

  def handle_info({:runtime_cancel, reason}, state), do: {:noreply, cancel(state, reason)}
  def handle_info(_message, state), do: {:noreply, state}

  defp cancel(%{signal: nil} = state, _reason), do: state

  defp cancel(%{signal: signal} = state, reason) do
    Cancellation.cancel(signal, reason)
    state
  end

  # A delegated run reports its outcome; the root agent has nobody to tell.
  defp finish(result, %{context: %AgentContext{terminal: %{} = terminal}} = state) do
    send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, result})
    {:noreply, state}
  end

  defp finish(_result, state), do: {:noreply, state}
end
