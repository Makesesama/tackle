defmodule Tackle.Web.Project.Source.Local do
  @moduledoc """
  A git repository on local disk.

  Nothing is cloned and nothing is fetched: the path the reviewer typed is the
  working tree, which is also the checkout the assistant reads. A review is a
  choice of two refs, so `load_review/2` accepts any diff the repository can
  describe — two branches, a branch and a tag, a commit and `HEAD` — and
  `branches/1` is what the picker offers as a starting point.

  The review id is `"<base>..<head>"`, with `/` in a ref replaced by `~`. Git
  forbids `~` in a ref name, so the substitution is reversible and the id stays
  a safe file name without escaping.
  """

  @behaviour Tackle.Web.Project.Source

  alias Tackle.Web.Diff
  alias Tackle.Web.Git, as: WebGit
  alias Tackle.Web.Project

  @impl true
  def build(attrs) do
    locator =
      attrs
      |> field("locator")
      |> to_string()
      |> String.trim()

    cond do
      locator == "" ->
        {:error, "Enter the path of a git repository."}

      not File.dir?(locator) ->
        {:error, "#{locator} is not a directory."}

      true ->
        locator = Path.expand(locator)

        case WebGit.validate(locator) do
          :ok -> {:ok, fields(locator)}
          {:error, _reason} -> {:error, "#{locator} is not a git repository."}
        end
    end
  end

  @impl true
  def checkout(%Project{locator: path}) do
    if WebGit.valid_repo?(path) do
      {:ok, path}
    else
      {:error, "#{path} is no longer a git repository. Was it moved or deleted?"}
    end
  end

  @impl true
  def branches(%Project{locator: path}), do: WebGit.branches(path)

  @impl true
  def list_reviews(%Project{}), do: {:ok, []}

  @impl true
  def load_review(%Project{locator: path} = project, review_id) do
    with {:ok, {base, head}} <- Project.parse_ref_review_id(review_id),
         {:ok, diff} <- Diff.load(path, base, head) do
      {:ok,
       %{
         review_id: review_id,
         title: "#{base}..#{head}",
         base_ref: base,
         head_ref: head,
         cwd: path,
         diff: diff,
         project: project
       }}
    else
      :error ->
        {:error, "#{review_id} is not a diff this project can load."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fields(locator) do
    {:ok, branches} = WebGit.branches(locator)

    %{
      kind: :local,
      locator: locator,
      name: Path.basename(locator),
      default_branch: default_branch(branches)
    }
  end

  # The branch the checkout is on is the reviewer's own starting point; failing
  # that, whichever of the two conventional names exists; failing that, whatever
  # the repository lists first.
  defp default_branch(branches) do
    branch =
      Enum.find(branches, & &1.current?) ||
        Enum.find(branches, &(&1.name in ["main", "master"])) ||
        List.first(branches)

    case branch do
      nil -> nil
      %{name: name} -> name
    end
  end

  defp field(attrs, key) when is_map(attrs), do: Map.get(attrs, key, "")
end
