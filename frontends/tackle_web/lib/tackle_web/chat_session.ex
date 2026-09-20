defmodule Tackle.Web.ChatSession do
  @moduledoc """
  Wires one chat conversation to a `Tackle.Phoenix.Runner`.

  LiveViews talk to this module rather than to `Tackle.Phoenix.Runner`, so the
  infrastructure names (Registry, supervisors, PubSub, store, agent) stay in one
  place, and so does the conversation: every entry point rebuilds the agent
  state from the stored transcript, which is what lets a Runner be recreated
  after its idle timeout without losing the conversation.

  A conversation is keyed by its own id, so a second viewer of the same
  conversation attaches to the same Runner and sees the same answers.
  """

  alias Tackle.Lib.State
  alias Tackle.Phoenix.Runner
  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatSessionStore
  alias Tackle.Web.ChatStore

  @config %{
    registry: Tackle.Web.AgentRegistry,
    dynamic_supervisor: Tackle.Web.AgentSupervisor,
    task_supervisor: Tackle.Web.AgentTaskSupervisor,
    pubsub: Tackle.Web.PubSub,
    store: ChatSessionStore,
    agent: ChatAgent
  }

  @typedoc """
  A conversation's current state, as the Runner reports it.

    * `:agent_state` — the `Tackle.Lib.State` a LiveView renders from.
    * `:turn_active?` — whether a turn is running.
    * `:runner_pid` — the turn owner while one is running, for cancellation.
  """
  @type snapshot :: %{
          agent_state: State.t(),
          session_id: String.t() | nil,
          turn_active?: boolean(),
          runner_pid: pid() | nil
        }

  @doc "Subscribes the caller to the conversation's turn events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id) when is_binary(id), do: Runner.subscribe(@config, id, nil)

  @doc """
  Reads the conversation atomically: agent state plus the active turn.

  Building the agent state here means a Runner recreated after its idle timeout
  resumes the stored conversation instead of starting an empty one. Returns
  `{:error, reason}` when the agent cannot be built at all — an unknown model
  reference, a missing directory, or no provider adapters.
  """
  @spec snapshot(ChatStore.conversation()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(%{id: id} = conversation) do
    with {:ok, agent_state} <- ChatAgent.new(restore(conversation)),
         {:ok, pid} <- runner(id, agent_state) do
      {:ok, Runner.snapshot(pid)}
    end
  end

  @doc """
  Asks the assistant a question, appending it to the conversation.

  `state` is the conversation's current state, not a fresh one: a turn continues
  the transcript that is already in the Runner.
  """
  @spec run_turn(String.t(), State.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def run_turn(id, %State{} = state, input) when is_binary(input) do
    Runner.run_turn(@config, id, state, input, turn_opts(id))
  end

  @doc "Retries the last question without appending a new one."
  @spec continue_turn(String.t(), State.t()) :: {:ok, pid()} | {:error, term()}
  def continue_turn(id, %State{} = state) do
    Runner.continue_turn(@config, id, state, turn_opts(id))
  end

  @doc """
  Switches the conversation to another model.

  The conversation is kept and only its configuration is rebuilt, so a model
  change is not a new conversation. Rejected while a turn is running, because
  the model that answers a question has to be the model the question was asked
  of.
  """
  @spec change_model(ChatStore.conversation(), State.t(), String.t()) ::
          {:ok, State.t()} | {:error, term()}
  def change_model(%{id: id} = conversation, %State{} = state, model) when is_binary(model) do
    with {:ok, rebuilt} <-
           ChatAgent.new(cwd: conversation.cwd, model: model, messages: state.messages),
         {:ok, pid} <- runner(id, rebuilt),
         :ok <- Runner.replace_state(pid, rebuilt, host_state(id)) do
      ChatStore.set_model(id, model)
      {:ok, rebuilt}
    end
  end

  @doc "Requests cooperative cancellation of the running turn."
  @spec cancel_turn(pid() | nil) :: :ok
  def cancel_turn(pid), do: Runner.cancel_turn(pid)

  # `Runner.get_or_start/3` looks the Runner up in a Registry and starts one if
  # it is absent, so two viewers opening the same conversation at once can both
  # see it as absent. The loser is told the process is already started and
  # simply has to ask again, now that the Registry knows about it.
  defp runner(id, agent_state) do
    opts = [agent_state: agent_state, host_state: host_state(id)]

    case Runner.get_or_start(@config, id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> Runner.get_or_start(@config, id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore(%{cwd: cwd, model: model, messages: messages}) do
    [cwd: cwd, model: model, messages: messages]
  end

  defp turn_opts(id) do
    [host_state: host_state(id), telemetry_metadata: %{source: :chat}]
  end

  defp host_state(id), do: %{conversation_id: id}
end
