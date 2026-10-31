defmodule Tackle.Phoenix.FakeBackend do
  @moduledoc false

  # Minimal `Tackle.Runtime.AgentBackend` for bridge tests. The agent runs no
  # turns: a test makes it publish an event with `{:emit, event}`.

  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec

  @impl true
  def validate_spec(%AgentSpec{config: config}) when is_map(config), do: :ok
  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_config, config}}

  @impl true
  def child_spec(%AgentSpec{config: config}, %AgentContext{} = context),
    do: {Tackle.Phoenix.FakeAgent, {config, context}}

  @impl true
  def call(pid, operation, args), do: GenServer.call(pid, {operation, args})
end

defmodule Tackle.Phoenix.FakeAgent do
  @moduledoc false

  use GenServer

  alias Tackle.Runtime.AgentContext

  def start_link({config, context}), do: GenServer.start_link(__MODULE__, {config, context})

  @impl true
  def init({config, %AgentContext{} = context}) do
    :ok = AgentContext.register(context)
    {:ok, %{config: config, subscribers: []}}
  end

  @impl true
  def handle_call({:subscribe, []}, {pid, _tag}, state) do
    case Map.get(state.config, :subscribe, {:ok, %{}}) do
      {:error, _reason} = error -> {:reply, error, state}
      reply -> {:reply, reply, %{state | subscribers: [pid | state.subscribers]}}
    end
  end

  def handle_call({operation, _args}, _from, state),
    do: {:reply, {:error, {:unsupported_agent_operation, operation}}, state}

  @impl true
  def handle_info({:emit, event}, state) do
    Enum.each(state.subscribers, &send(&1, {:tackle_event, "session", "turn", event}))
    {:noreply, state}
  end
end
