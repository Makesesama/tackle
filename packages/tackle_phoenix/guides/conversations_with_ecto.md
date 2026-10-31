# Conversations with Ecto

This guide builds a chat whose conversations survive restarts, deploys, and
idle periods, with `Tackle.Runtime.LoopAgent`, `Tackle.Phoenix`, and Ecto on
PostgreSQL. It is an example to adapt, not part of the package: names such as
`MyApp.Chats` are yours.

## Who keeps what

| Concern | Owner |
|---|---|
| Conversations, messages, ownership | your database (this guide) |
| Saving each settled message | a `Tackle.Lib.Hook` you configure |
| Loading a conversation back | your code, passed to `LoopAgent.Config.new/1` |
| Running turns, streaming, cancellation | `Tackle.Runtime.LoopAgent` |
| Stopping agents nobody uses | `LoopAgent`'s `:idle_timeout` |
| Finding a conversation's running agent | a `Registry` of `Tackle.Phoenix.Bridge`s |
| Relaying events to LiveViews | `Tackle.Phoenix.Bridge` |

The runtime stores nothing and looks nothing up. A conversation's agent runs
while it is used; when it has been idle for `:idle_timeout`, its scope stops,
and the next message starts a new agent from the saved transcript. The agent's
`session_id` is set to the conversation's id, so the hook always knows which
conversation a message belongs to.

## 1. Tables and schemas

```elixir
defmodule MyApp.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:user_id])

    create table(:conversation_messages, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      # The Tackle.Lib.Message id, and the order messages were saved in.
      add :message_id, :string, null: false
      add :seq, :bigserial, null: false
      # Queryable copies; `data` is the message itself.
      add :role, :string, null: false
      add :content, :text
      add :data, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:conversation_messages, [:conversation_id, :message_id])
    create index(:conversation_messages, [:conversation_id, :seq])
  end
end
```

```elixir
defmodule MyApp.Chats.Conversation do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :title, :string
    belongs_to :user, MyApp.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule MyApp.Chats.StoredMessage do
  use Ecto.Schema

  @primary_key false

  schema "conversation_messages" do
    field :conversation_id, :binary_id
    field :message_id, :string
    field :seq, :integer, read_after_writes: true
    field :role, :string
    field :content, :string
    field :data, :binary
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

`data` holds the whole `Tackle.Lib.Message` as `:erlang.term_to_binary/1`.
Messages carry tool calls, usage, content parts, and provider continuation
state, some with atom keys, which a JSON column would not give back
unchanged. Only your server writes `data`, and it is read back with
`:erlang.binary_to_term(data, [:safe])`. Copy into other columns whatever you
want to query or show without the agent.

## 2. Save every settled message

The loop calls `after_message/3` for each message it settles: the user's
message, every assistant step, every tool result, and the results it adds when
it repairs a turn that stopped with unanswered tool calls. Saving there keeps
the database in step with what the views show.

```elixir
defmodule MyApp.Chats.SaveMessages do
  @behaviour Tackle.Lib.Hook

  alias MyApp.Chats.StoredMessage
  alias MyApp.Repo

  @impl true
  def after_message(state, message, _context) do
    %StoredMessage{
      # The agent runs with the conversation's id as its session id.
      conversation_id: state.session_id,
      message_id: message.id,
      role: Atom.to_string(message.role),
      content: message.content,
      data: :erlang.term_to_binary(message)
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:conversation_id, :message_id])
    |> case do
      {:ok, _stored} -> :ok
      {:error, changeset} -> {:error, {:message_not_saved, changeset.errors}}
    end
  end
end
```

A hook error ends the turn with an error, so a message that cannot be saved
is not silently lost. The hook runs in the turn's task; keep it to the one
insert.

## 3. Start, find, and restart a conversation's agent

One `Tackle.Phoenix.Bridge` per running conversation is registered under the
conversation's id. The bridge stops when its agent does, so the registry
always names the conversations that run now, and `Bridge.agent_ref/1` gives
the agent.

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Registry, keys: :unique, name: MyApp.Chats.Registry},
  {DynamicSupervisor, name: MyApp.Chats.BridgeSupervisor, strategy: :one_for_one},
  MyAppWeb.Endpoint
]
```

```elixir
defmodule MyApp.Chats do
  import Ecto.Query

  alias MyApp.Chats.{Conversation, SaveMessages, StoredMessage}
  alias MyApp.Repo
  alias Tackle.Phoenix.Bridge
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, LoopAgent, ScopeSpec}

  @registry MyApp.Chats.Registry

  @doc "The user's conversation, or raises: authorize before anything else."
  def get_conversation!(user, id), do: Repo.get_by!(Conversation, id: id, user_id: user.id)

  def topic(%Conversation{id: id}), do: "conversation:#{id}"

  @doc "Submits `input`, starting the conversation's agent when it is not running."
  def submit(%Conversation{} = conversation, input, attempts \\ 3) do
    with {:ok, agent_ref} <- ensure_started(conversation) do
      case Runtime.submit(agent_ref, input) do
        {:ok, _turn} ->
          {:ok, agent_ref}

        # The agent went idle and is stopping: wait for it, then start anew.
        {:error, :agent_stopping} when attempts > 1 ->
          await_exit(agent_ref)
          submit(conversation, input, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def cancel(%Conversation{} = conversation) do
    case running(conversation) do
      {:ok, agent_ref} -> Runtime.cancel_turn(agent_ref)
      :error -> :ok
    end
  end

  @doc "Visible text of the answer being streamed, for a view that joins mid-turn."
  def streaming(%Conversation{id: id}) do
    Bridge.streaming(via(id))
  catch
    :exit, _not_running -> %{}
  end

  @doc "Returns the running agent, or starts one from the saved transcript."
  def ensure_started(conversation, attempts \\ 3)
  def ensure_started(_conversation, 0), do: {:error, :conversation_unavailable}

  def ensure_started(%Conversation{} = conversation, attempts) do
    with :error <- running(conversation),
         :retry <- start(conversation) do
      ensure_started(conversation, attempts - 1)
    end
  end

  defp running(%Conversation{id: id}) do
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
         pubsub: MyApp.PubSub,
         topic: topic(conversation),
         name: via(conversation.id)}

      case DynamicSupervisor.start_child(MyApp.Chats.BridgeSupervisor, bridge) do
        {:ok, _bridge} ->
          {:ok, scope.root_agent_ref}

        # Another request started it first, or the old bridge is still
        # stopping: drop this agent and look again.
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
      providers: MyApp.AI.providers(),
      model: "provider/model",
      system_prompt: "You are a helpful assistant.",
      hooks: [SaveMessages],
      # Where the agent starts, and the id the hook files messages under.
      session_id: conversation.id,
      messages: load_messages(conversation.id),
      idle_timeout: :timer.minutes(30)
    )
  end

  defp load_messages(conversation_id) do
    StoredMessage
    |> where(conversation_id: ^conversation_id)
    |> order_by(:seq)
    |> select([m], m.data)
    |> Repo.all()
    |> Enum.map(&:erlang.binary_to_term(&1, [:safe]))
  end

  defp via(id), do: {:via, Registry, {@registry, id}}
end
```

`ensure_started/1` is safe to call from many processes at once: only one
bridge can register under a conversation's id, and the loser stops the agent
it started. An agent that has gone idle refuses new turns with
`{:error, :agent_stopping}` while its scope stops, so `submit/3` waits for
it and starts a new one rather than losing the message. The registry is node-local; a cluster needs to route a
conversation's requests to one node.

## 4. The LiveView

The view subscribes once, keeps no agent reference of its own, and goes
through `MyApp.Chats` for every action, so an agent that idled out is started
again by the next message without a reload.

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  alias MyApp.Chats
  alias Tackle.Phoenix.EventReducer

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    conversation = Chats.get_conversation!(socket.assigns.current_scope.user, id)

    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(MyApp.PubSub, Chats.topic(conversation))

    # Subscribe first, then read: nothing is missed in between.
    {:ok, agent_ref} = Chats.ensure_started(conversation)
    {:ok, snapshot} = Tackle.Runtime.session_snapshot(agent_ref)

    {:ok,
     socket
     |> assign(conversation: conversation, agent_state: snapshot.agent_state)
     |> assign(processing: snapshot.active_turn != nil, agent_error: nil)
     |> assign(:tackle_message_view, MyAppWeb.AgentMessageView)
     |> EventReducer.init_stream(snapshot.agent_state)
     |> EventReducer.restore_streaming_messages(Chats.streaming(conversation))}
  end

  @impl true
  def handle_event("submit", %{"input" => input}, socket) do
    case Chats.submit(socket.assigns.conversation, input) do
      {:ok, _agent_ref} -> {:noreply, assign(socket, processing: true, agent_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, :agent_error, reason)}
    end
  end

  def handle_event("cancel", _params, socket) do
    :ok = Chats.cancel(socket.assigns.conversation)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_event, %Tackle.Lib.Event{} = event}, socket) do
    socket = EventReducer.handle_tackle_event(socket, event)
    processing = socket.assigns.processing and event.type != :turn_end
    {:noreply, assign(socket, :processing, processing)}
  end

  # The agent idled out or stopped. Its messages are saved, and the view
  # already shows them; the next message starts a new agent from them.
  def handle_info({:agent_down, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:processing, false)
     |> EventReducer.clear_streaming_messages()}
  end
end
```

`mount/3` matches `{:ok, _}` for brevity. If the agent cannot start, or
idles out between `ensure_started/1` and the snapshot, mount raises and the
client mounts again, which starts the conversation anew; handle the errors
instead to show a message. Mount starts the agent on the static render too. If that is not wanted, for
example for crawlers, render the saved messages from `MyApp.Chats` until the
socket connects.

## What this does not cover

- **Quota and billing.** Check quota in `MyApp.Chats.submit/2` before the
  turn; turns of subagents and workflows need a `before_prompt/2` hook, which
  can refuse a step. Usage is on assistant messages (`token_usage`) and in
  `:usage` events.
- **Crashed turns.** Hooks do not run when a turn's task crashes. Messages
  saved before the crash stay saved; the views receive `:turn_end` with status
  `:error`.
- **Branching.** This guide saves one transcript. A host that lets users edit
  earlier messages saves its `Tackle.Lib.Tree` and passes it as `:tree`.
