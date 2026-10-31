defmodule Tackle.Phoenix.Test.Chats do
  @moduledoc false

  # `MyApp.Chats` from guides/conversations_with_ecto.md, with an in-memory
  # store in place of the Repo, so the guide's runtime code is tested: the
  # bridge registry, starting from saved messages, idle restarts, and
  # concurrent starts. A conversation here is a map with the guide's `:id`
  # and the test's `:test_pid` and `:idle_timeout`.

  alias Tackle.Phoenix.Bridge
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.LoopAgent
  alias Tackle.Runtime.ScopeSpec

  @registry __MODULE__.Registry
  @supervisor __MODULE__.BridgeSupervisor
  @pubsub __MODULE__.PubSub

  defmodule Store do
    @moduledoc false
    # The conversation_messages table: messages per conversation, in order,
    # unique by id.
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def insert(conversation_id, message) do
      Agent.update(__MODULE__, fn conversations ->
        Map.update(conversations, conversation_id, [message], fn messages ->
          if Enum.any?(messages, &(&1.id == message.id)),
            do: messages,
            else: messages ++ [message]
        end)
      end)
    end

    def all(conversation_id), do: Agent.get(__MODULE__, &Map.get(&1, conversation_id, []))
  end

  defmodule SaveMessages do
    @moduledoc false
    @behaviour Tackle.Lib.Hook

    @impl true
    def after_message(state, message, _context) do
      Store.insert(state.session_id, message)
      :ok
    end
  end

  def children do
    [
      Store,
      {Phoenix.PubSub, name: @pubsub},
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  def pubsub, do: @pubsub
  def topic(%{id: id}), do: "conversation:#{id}"

  def submit(conversation, input, attempts \\ 3) do
    with {:ok, agent_ref} <- ensure_started(conversation) do
      case Runtime.submit(agent_ref, input) do
        {:ok, _turn} ->
          {:ok, agent_ref}

        {:error, :agent_stopping} when attempts > 1 ->
          await_exit(agent_ref)
          submit(conversation, input, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def cancel(conversation) do
    case running(conversation) do
      {:ok, agent_ref} -> Runtime.cancel_turn(agent_ref)
      :error -> :ok
    end
  end

  def streaming(%{id: id}) do
    Bridge.streaming(via(id))
  catch
    :exit, _not_running -> %{}
  end

  def ensure_started(conversation, attempts \\ 3)
  def ensure_started(_conversation, 0), do: {:error, :conversation_unavailable}

  def ensure_started(conversation, attempts) do
    with :error <- running(conversation),
         :retry <- start(conversation) do
      ensure_started(conversation, attempts - 1)
    end
  end

  def running(%{id: id}) do
    case Registry.lookup(@registry, id) do
      [] ->
        :error

      [{bridge, _value}] ->
        agent_ref = Bridge.agent_ref(bridge)

        case Runtime.session_pid(agent_ref) do
          {:ok, _pid} ->
            {:ok, agent_ref}

          # The agent is gone and its bridge is leaving the registry.
          {:error, _reason} ->
            await_exit(bridge)
            :error
        end
    end
  catch
    # The bridge stopped between the lookup and the call.
    :exit, _reason -> :error
  end

  defp await_exit(%Runtime.AgentRef{} = agent_ref) do
    case Runtime.session_pid(agent_ref) do
      {:ok, pid} -> await_exit(pid)
      {:error, _gone} -> :ok
    end
  end

  defp await_exit(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp start(conversation) do
    with {:ok, config} <- agent_config(conversation),
         {:ok, scope} <-
           Runtime.start_scope(
             ScopeSpec.new!(
               backend: LoopAgent,
               root_spec: AgentSpec.new!(name: "chat", config: config)
             )
           ) do
      bridge =
        {Bridge,
         agent_ref: scope.root_agent_ref,
         pubsub: @pubsub,
         topic: topic(conversation),
         name: via(conversation.id)}

      case DynamicSupervisor.start_child(@supervisor, bridge) do
        {:ok, _bridge} ->
          {:ok, scope.root_agent_ref}

        {:error, {:already_started, _bridge}} ->
          Runtime.stop_scope(scope.scope_ref)
          :retry

        {:error, reason} ->
          Runtime.stop_scope(scope.scope_ref)
          {:error, reason}
      end
    end
  end

  defp agent_config(conversation) do
    LoopAgent.Config.new(
      providers: [Tackle.Phoenix.Test.LLM],
      model: "test/chat",
      llm_opts: [test_pid: conversation.test_pid],
      hooks: [SaveMessages],
      session_id: conversation.id,
      messages: Store.all(conversation.id),
      idle_timeout: conversation.idle_timeout
    )
  end

  defp via(id), do: {:via, Registry, {@registry, id}}
end
