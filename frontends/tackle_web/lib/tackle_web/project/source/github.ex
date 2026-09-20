defmodule Tackle.Web.Project.Source.GitHub do
  @moduledoc """
  A repository on GitHub.

  The reviews it offers are the open pull requests, because that is what a
  GitHub repository has that is ready to review without anyone describing it. A
  pull request id is `"pr-<number>"`; it is opaque to everything outside this
  module, which is what lets the URL scheme, the review store and the transcript
  treat a pull request and a local ref range the same way.

  `checkout/1` is the clone a chat runs in: the base clone of the default
  branch, which is also the clone pull requests are fetched into.
  """

  @behaviour Tackle.Web.Project.Source

  alias Tackle.Web.Diff
  alias Tackle.Web.GitHub
  alias Tackle.Web.Project
  alias Tackle.Web.RepoCache

  @pull_prefix "pr-"

  @impl true
  def build(attrs) do
    locator =
      attrs
      |> Map.get("locator", "")
      |> to_string()
      |> String.trim()

    with {:ok, {owner, name}} <- GitHub.parse_repository(locator),
         {:ok, repository} <- GitHub.repository(owner, name) do
      {:ok,
       %{
         kind: :github,
         locator: "#{owner}/#{name}",
         name: name,
         default_branch: repository.default_branch
       }}
    end
  end

  @impl true
  def checkout(%Project{locator: locator, default_branch: branch}) do
    with {:ok, {owner, name}} <- split(locator) do
      RepoCache.default_checkout(owner, name, branch)
    end
  end

  # Every review of this source is described by the source, so there is no
  # branch picker to fill.
  @impl true
  def branches(%Project{}), do: {:ok, []}

  @impl true
  def list_reviews(%Project{locator: locator}) do
    with {:ok, {owner, name}} <- split(locator),
         {:ok, pulls} <- GitHub.pull_requests(owner, name) do
      {:ok, Enum.map(pulls, &summary/1)}
    end
  end

  @impl true
  def load_review(%Project{locator: locator} = project, review_id) do
    with {:ok, {owner, name}} <- split(locator),
         {:ok, number} <- pull_number(review_id),
         {:ok, pull} <- GitHub.pull(owner, name, number),
         {:ok, path} <- RepoCache.pull_request_checkout(owner, name, number, pull.base_ref),
         {:ok, diff} <-
           Diff.load(path, RepoCache.base_ref(pull.base_ref), RepoCache.pull_ref(number)) do
      {:ok,
       %{
         review_id: review_id,
         title: pull.title,
         base_ref: pull.base_ref,
         head_ref: pull.head_ref,
         cwd: path,
         diff: diff,
         project: project,
         pull: pull
       }}
    end
  end

  @doc "The review id of a pull request."
  @spec review_id(pos_integer()) :: String.t()
  def review_id(number) when is_integer(number), do: @pull_prefix <> Integer.to_string(number)

  defp split(locator) do
    case String.split(locator, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {:ok, {owner, name}}
      _other -> {:error, "#{locator} is not an owner/name repository."}
    end
  end

  defp pull_number(@pull_prefix <> number) do
    case Integer.parse(number) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> {:error, "#{@pull_prefix}#{number} is not a pull request."}
    end
  end

  defp pull_number(_review_id), do: {:error, "This project reviews pull requests."}

  defp summary(pull) do
    %{
      review_id: review_id(pull.number),
      title: pull.title,
      author: pull.author,
      base_ref: pull.base_ref,
      head_ref: pull.head_ref
    }
  end
end
