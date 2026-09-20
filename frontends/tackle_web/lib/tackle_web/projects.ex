defmodule Tackle.Web.Projects do
  @moduledoc """
  The project API: everything the frontend asks of a project, in one place.

  Screens call this module rather than a source module, so which of
  `Tackle.Web.Project.Source.Local` or `...Source.GitHub` implements a project
  is decided here and nowhere else — see `Tackle.Web.Project.Source` for the
  contract itself.

  `create/1` is the only function that is more than a dispatch: it turns the
  add-project form's input into a stored project. Building happens outside the
  store, so a GitHub lookup does not block the project list, and storing happens
  inside it, so two tabs cannot add the same locator twice.
  """

  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore

  @doc "Lists the projects, most recently added first."
  @spec list() :: [Project.t()]
  defdelegate list(), to: ProjectStore

  @doc "Returns a project by slug, or `nil` when it is unknown."
  @spec get(String.t()) :: Project.t() | nil
  defdelegate get(slug), to: ProjectStore

  @doc "Forgets a project. Unknown slugs are ignored."
  @spec remove(String.t()) :: :ok
  defdelegate remove(slug), to: ProjectStore

  @doc "Subscribes the caller to project-list changes."
  @spec subscribe() :: :ok
  defdelegate subscribe(), to: ProjectStore

  @doc "The kinds of project the add form offers."
  @spec kinds() :: [Project.kind()]
  defdelegate kinds(), to: Project

  @doc """
  Builds and stores a project from the add-project form.

  Returns `{:error, message}` with something to show on the form: unknown kind,
  input the source rejected, or a locator that is already a project.
  """
  @spec create(map()) :: {:ok, Project.t()} | {:error, String.t()}
  def create(attrs) when is_map(attrs) do
    with {:ok, kind} <- kind(attrs),
         {:ok, fields} <- source(kind).build(attrs) do
      store(project(kind, fields))
    else
      :error -> {:error, "Choose the kind of project to add."}
      {:error, message} -> {:error, message}
    end
  end

  @doc "A working tree of the project, used as a chat's working directory."
  @spec checkout(Project.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def checkout(%Project{} = project), do: source(project).checkout(project)

  @doc "The branches a review can be opened between."
  @spec branches(Project.t()) ::
          {:ok, [Tackle.Web.Project.Source.branch()]} | {:error, String.t()}
  def branches(%Project{} = project), do: source(project).branches(project)

  @doc "Reviews the project offers ready-made."
  @spec list_reviews(Project.t()) ::
          {:ok, [Tackle.Web.Project.Source.review_summary()]} | {:error, String.t()}
  def list_reviews(%Project{} = project), do: source(project).list_reviews(project)

  @doc "Loads one review: its diff, its metadata and its working tree."
  @spec load_review(Project.t(), String.t()) ::
          {:ok, Tackle.Web.Project.Source.loaded_review()} | {:error, String.t()}
  def load_review(%Project{} = project, review_id) when is_binary(review_id) do
    source(project).load_review(project, review_id)
  end

  defp kind(attrs) do
    attrs
    |> Map.get("kind", "")
    |> then(&Project.kind/1)
  end

  defp project(kind, fields) do
    %Project{
      slug: Project.slug(kind, fields.locator),
      kind: kind,
      locator: fields.locator,
      name: fields.name,
      default_branch: fields.default_branch
    }
  end

  defp store(%Project{} = project) do
    case ProjectStore.put(project) do
      {:ok, project} -> {:ok, project}
      {:error, {:duplicate, existing}} -> {:error, "#{existing.name} is already added."}
    end
  end

  defp source(%Project{} = project), do: Project.source(project)
  defp source(kind), do: Project.source(kind)
end
