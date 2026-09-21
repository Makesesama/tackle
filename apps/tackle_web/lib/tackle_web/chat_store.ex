defmodule Tackle.Web.ChatStore do
  @moduledoc """
  In-memory conversations for the chat frontend, scoped to a project.

  A conversation belongs to the frontend rather than to the browser tab that
  started it, so it lives in one process above the LiveViews and every viewer
  reads and writes it there. Unlike `Tackle.Web.ReviewStore`, nothing is written
  to disk: conversations exist while the server runs, and restarting the
  frontend starts from an empty list. There is no database behind this by
  design — the shape here is what a durable store would have to keep.

  Each conversation remembers the project it belongs to, the directory it was
  started in and the model it runs, because all three are part of what a
  conversation is: the project decides which checkout the assistant reads, and
  resuming a transcript with a different model is a supported change rather than
  a new conversation.

  Mutations are announced on `chat:conversations`, so a sidebar open elsewhere
  learns that a conversation was created, renamed by its first question, or
  deleted.
  """

  use GenServer

  alias Tackle.Lib.ID
  alias Tackle.Lib.Message

  @topic "chat:conversations"

  @typedoc "A conversation and everything needed to resume it."
  @type conversation :: %{
          id: String.t(),
          title: String.t(),
          model: String.t() | nil,
          project_slug: String.t(),
          cwd: Path.t(),
          messages: [Message.t()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc "The list projection of a conversation: no messages, just what a sidebar shows."
  @type summary :: %{
          id: String.t(),
          title: String.t(),
          model: String.t() | nil,
          project_slug: String.t(),
          cwd: Path.t(),
          message_count: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @untitled "New chat"

  # -- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists one project's conversations, most recently updated first, without their
  messages.

  A conversation belongs to a project because the project is what decides the
  directory the assistant reads; there is no such thing as a conversation
  without one.
  """
  @spec list(String.t()) :: [summary()]
  def list(project_slug) when is_binary(project_slug),
    do: GenServer.call(__MODULE__, {:list, project_slug})

  @doc "Returns a conversation, messages and all, or `nil` when it is unknown."
  @spec get(String.t()) :: conversation() | nil
  def get(id) when is_binary(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc """
  Creates a conversation in `:cwd` running `:model`, inside `:project_slug`.

  The directory has to exist: a conversation whose every tool call would fail is
  rejected here rather than at the first question.
  """
  @spec create(keyword()) :: {:ok, conversation()} | {:error, term()}
  def create(attrs) when is_list(attrs), do: GenServer.call(__MODULE__, {:create, attrs})

  @doc "Replaces a conversation's transcript. Unknown ids are ignored."
  @spec put_messages(String.t(), [Message.t()]) :: :ok
  def put_messages(id, messages) when is_binary(id) and is_list(messages) do
    GenServer.call(__MODULE__, {:put_messages, id, messages})
  end

  @doc """
  Appends one message, as the Runner does with a user message before it starts
  working on it.

  The first user message also names the conversation: a transcript that has a
  title is easier to return to than a list of timestamps.
  """
  @spec append_message(String.t(), Message.t()) :: :ok
  def append_message(id, %Message{} = message),
    do: GenServer.call(__MODULE__, {:append, id, message})

  @doc "Records which model the conversation runs. Unknown ids are ignored."
  @spec set_model(String.t(), String.t()) :: :ok
  def set_model(id, model) when is_binary(id) and is_binary(model) do
    GenServer.call(__MODULE__, {:set_model, id, model})
  end

  @doc "Forgets a conversation."
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Subscribes the caller to conversation-list changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Tackle.Web.PubSub, @topic)

  @doc "Topic on which conversation-list changes are announced."
  @spec topic() :: String.t()
  def topic, do: @topic

  # -- server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{conversations: %{}}}
  end

  @impl true
  def handle_call({:list, project_slug}, _from, state) do
    summaries =
      state.conversations
      |> Map.values()
      |> Enum.filter(&(&1.project_slug == project_slug))
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.map(&summarize/1)

    {:reply, summaries, state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state.conversations, id), state}
  end

  def handle_call({:create, attrs}, _from, state) do
    case build(attrs) do
      {:ok, conversation} ->
        state = put(state, conversation)
        broadcast({:chat_updated, conversation.id})
        {:reply, {:ok, conversation}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_messages, id, messages}, _from, state) do
    {:reply, :ok, update_conversation(state, id, &%{&1 | messages: messages})}
  end

  def handle_call({:append, id, message}, _from, state) do
    fun = fn conversation ->
      conversation
      |> Map.update!(:messages, &(&1 ++ [message]))
      |> retitle(message)
    end

    {:reply, :ok, update_conversation(state, id, fun)}
  end

  def handle_call({:set_model, id, model}, _from, state) do
    {:reply, :ok, update_conversation(state, id, &%{&1 | model: model})}
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.conversations, id) do
      broadcast({:chat_deleted, id})
      {:reply, :ok, %{state | conversations: Map.delete(state.conversations, id)}}
    else
      {:reply, :ok, state}
    end
  end

  # -- internals ------------------------------------------------------------

  defp build(attrs) do
    with {:ok, project_slug} <- normalize_project(Keyword.get(attrs, :project_slug)),
         {:ok, cwd} <- normalize_cwd(Keyword.get(attrs, :cwd)) do
      {:ok, new(cwd, Keyword.get(attrs, :model), project_slug)}
    end
  end

  defp normalize_project(slug) when is_binary(slug) and slug != "", do: {:ok, slug}
  defp normalize_project(slug), do: {:error, {:invalid_project, slug}}

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "" do
    cwd = Path.expand(cwd)
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, {:workspace_missing, cwd}}
  end

  defp normalize_cwd(cwd), do: {:error, {:invalid_workspace, cwd}}

  defp new(cwd, model, project_slug) do
    now = DateTime.utc_now()

    %{
      id: ID.uuid4(),
      title: @untitled,
      model: model,
      project_slug: project_slug,
      cwd: cwd,
      messages: [],
      inserted_at: now,
      updated_at: now
    }
  end

  defp put(state, conversation) do
    %{state | conversations: Map.put(state.conversations, conversation.id, conversation)}
  end

  defp update_conversation(state, id, fun) do
    case Map.fetch(state.conversations, id) do
      {:ok, conversation} ->
        conversation = conversation |> fun.() |> touch()
        put(state, conversation) |> tap(fn _state -> broadcast({:chat_updated, id}) end)

      :error ->
        state
    end
  end

  defp touch(conversation), do: %{conversation | updated_at: DateTime.utc_now()}

  # The first question is the best title available: it is what the conversation
  # is about, and it costs no extra model call. Later questions leave it alone.
  defp retitle(%{title: @untitled} = conversation, %Message{role: :user, content: content})
       when is_binary(content) do
    case title_of(content) do
      "" -> conversation
      title -> %{conversation | title: title}
    end
  end

  defp retitle(conversation, _message), do: conversation

  defp title_of(content) do
    content
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
    |> String.slice(0, 60)
  end

  defp summarize(conversation) do
    conversation
    |> Map.take([:id, :title, :model, :project_slug, :cwd, :inserted_at, :updated_at])
    |> Map.put(:message_count, length(conversation.messages))
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Tackle.Web.PubSub, @topic, message)
  end
end
