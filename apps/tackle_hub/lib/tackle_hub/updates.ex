defmodule Tackle.Hub.Updates do
  @moduledoc """
  Live updates for the signed-in pages: an Ash notifier on the resources
  the pages show that tells them, over `Tackle.Hub.PubSub`, that something
  they show changed.

  Ash sends notifications once the write is committed, also for writes
  inside `Ash.transact/3` (and `Tackle.Hub.ReviewJob.Store`'s transactions,
  which run in one), so a page never reads uncommitted state. A message
  carries only its topic, `{Tackle.Hub.Updates, topic}`, never the record:
  each page reads again with its user as the actor, so the policies decide
  what it shows, as on the first read.

  Topics, by what changed:

    * `review/1` - a review request or one of its runs;
    * `run/1` - a run's findings (posted comments, reactions);
    * `repository/1` - a repository, or one of its review requests;
    * `dismissals/1` - the findings dismissed in a repository;
    * `installation/1` - an installation, its repositories, or its grants;
    * `installations/0` - any installation or grant, which may change
      what someone sees;
    * `user/1` - a user's model providers or review defaults.

  A review in progress reports on `review/1` as well
  (`Tackle.Hub.ReviewProgress`).
  """

  use Ash.Notifier

  alias Tackle.Hub.Forges.{Access, Installation, Repository}
  alias Tackle.Hub.Models.{Provider, ReviewDefaults}
  alias Tackle.Hub.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  @pubsub Tackle.Hub.PubSub

  @doc "Topic of a review request: its status and runs."
  @spec review(Ecto.UUID.t()) :: String.t()
  def review(id), do: "review:" <> id

  @doc "Topic of a run's findings."
  @spec run(Ecto.UUID.t()) :: String.t()
  def run(id), do: "run:" <> id

  @doc "Topic of a repository and its review requests."
  @spec repository(Ecto.UUID.t()) :: String.t()
  def repository(id), do: "repository:" <> id

  @doc "Topic of the findings dismissed in a repository."
  @spec dismissals(Ecto.UUID.t()) :: String.t()
  def dismissals(repository_id), do: "dismissals:" <> repository_id

  @doc "Topic of an installation, its repositories, and its grants."
  @spec installation(Ecto.UUID.t()) :: String.t()
  def installation(id), do: "installation:" <> id

  @doc "Topic of every installation and grant."
  @spec installations() :: String.t()
  def installations, do: "installations"

  @doc "Topic of a user's model providers and review defaults."
  @spec user(Ecto.UUID.t()) :: String.t()
  def user(id), do: "user:" <> id

  @doc "Subscribes the calling process to `topic`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Unsubscribes the calling process from `topic`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  @doc """
  Sends `message` to the subscribers of `topic`; nothing when PubSub is
  not running, as in a release's migration task.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) do
    if Process.whereis(@pubsub), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
    :ok
  end

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{resource: resource, data: data}) do
    resource
    |> topics(data)
    |> Enum.each(&broadcast(&1, {__MODULE__, &1}))
  end

  @doc false
  @spec topics(Ash.Resource.t(), Ash.Resource.record()) :: [String.t()]
  def topics(ReviewRequest, request),
    do: [review(request.id), repository(request.repository_id)]

  def topics(ReviewRun, run), do: [review(run.request_id)]
  def topics(Finding, finding), do: [run(finding.run_id)]
  def topics(Dismissal, dismissal), do: [dismissals(dismissal.repository_id)]

  def topics(Repository, repository),
    do: [repository(repository.id), installation(repository.installation_id)]

  def topics(Installation, installation), do: [installation(installation.id), installations()]
  def topics(Access, access), do: [installation(access.installation_id), installations()]
  def topics(Provider, provider), do: [user(provider.owner_id)]
  def topics(ReviewDefaults, defaults), do: [user(defaults.user_id)]
  def topics(_resource, _data), do: []
end
