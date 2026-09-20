defmodule Tackle.Web.ProjectStore do
  @moduledoc """
  The projects this frontend knows about.

  In memory, deliberately: a project is a working context rather than a
  document, and nothing here is written to disk yet. Restarting the frontend
  starts from an empty list, and adding the same locator again is what brings a
  project back. Because a slug is derived from the kind and the locator, the
  review comments and assistant transcripts already on disk under that slug are
  found again rather than orphaned.

  Projects belong to the frontend rather than to a browser tab, so they live in
  one process above the LiveViews. Mutations are announced on `projects:updated`
  so a page open elsewhere learns that a project was added or removed.

  The slug is the key, and it already encodes `{kind, locator}`, so a duplicate
  is simply a slug that is taken — see `Tackle.Web.Project.slug/2` for why two
  different locators cannot collide.
  """

  use GenServer

  alias Tackle.Web.Project

  @topic "projects:updated"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Lists the projects, most recently added first."
  @spec list() :: [Project.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Returns a project by slug, or `nil` when it is unknown."
  @spec get(String.t()) :: Project.t() | nil
  def get(slug) when is_binary(slug), do: GenServer.call(__MODULE__, {:get, slug})

  @doc """
  Stores a project.

  Returns `{:error, {:duplicate, existing}}` when the slug is taken, which is
  the same as `{kind, locator}` already being known.
  """
  @spec put(Project.t()) :: {:ok, Project.t()} | {:error, {:duplicate, Project.t()}}
  def put(%Project{} = project), do: GenServer.call(__MODULE__, {:put, project})

  @doc "Forgets a project. Unknown slugs are ignored."
  @spec remove(String.t()) :: :ok
  def remove(slug) when is_binary(slug), do: GenServer.call(__MODULE__, {:remove, slug})

  @doc "Subscribes the caller to project-list changes."
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(pubsub(), @topic)

  @doc "Topic on which project-list changes are announced."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(_opts), do: {:ok, %{projects: %{}, order: []}}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, ordered(state), state}

  @impl true
  def handle_call({:get, slug}, _from, state), do: {:reply, Map.get(state.projects, slug), state}

  @impl true
  def handle_call({:put, project}, _from, state) do
    case Map.get(state.projects, project.slug) do
      nil ->
        project = %{project | inserted_at: project.inserted_at || DateTime.utc_now()}

        state = %{
          state
          | projects: Map.put(state.projects, project.slug, project),
            order: [project.slug | state.order]
        }

        broadcast()
        {:reply, {:ok, project}, state}

      existing ->
        {:reply, {:error, {:duplicate, existing}}, state}
    end
  end

  @impl true
  def handle_call({:remove, slug}, _from, state) do
    state = %{
      state
      | projects: Map.delete(state.projects, slug),
        order: List.delete(state.order, slug)
    }

    broadcast()
    {:reply, :ok, state}
  end

  # `order` is newest first, because that is how a project is prepended.
  defp ordered(state) do
    Enum.flat_map(state.order, &List.wrap(Map.get(state.projects, &1)))
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(pubsub(), @topic, {:projects_updated, @topic})

  defp pubsub do
    Application.get_env(:tackle_web, :pubsub_server, Tackle.Web.PubSub)
  end
end
