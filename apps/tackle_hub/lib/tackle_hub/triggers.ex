defmodule Tackle.Hub.Triggers do
  @moduledoc """
  When a pull request gets reviewed (docs/TACKLE_HUB_PLAN.md §7.7).

  **Automatic reviews.** With `auto_review: :on_open`, a pull request is
  reviewed when it is opened, reopened, or marked ready for review; with
  `:on_open_and_push`, also for every new head. Drafts are skipped unless
  `auto_review_drafts`, and reviewed once they are ready; heads from forks
  are skipped unless `auto_review_forks`.

  **Commands.** `/tackle review [profile]` from someone with write access
  reviews the pull request's current head, whatever `auto_review` says,
  forks and drafts included. Comments are checked here; the permission check
  and the forge call for the current head happen in
  `Tackle.Hub.Triggers.CommandJob`, outside the webhook request.

  Only enabled repositories the app can still access are reviewed.

  **One request per head.** A request for a head that already has one
  normally changes nothing, so redelivered webhooks and a command after an
  automatic review of the same head are no-ops. It runs again when:

    * a command asks for a head whose request failed or was skipped;
    * a command asks for a finished (posted) head with a different profile;
    * an automatic trigger (a pull request reopened) meets a skipped one.

  A request for a new head skips the pending requests for older heads of
  the same pull request, so a burst of pushes reviews only the last.
  Closing a pull request skips its pending requests.
  """

  require Logger

  alias Tackle.Hub.Accounts.User
  alias Tackle.Hub.Command
  alias Tackle.Hub.Forge
  alias Tackle.Hub.Forges.{ForgeApp, Installation, Repository}
  alias Tackle.Hub.Posting
  alias Tackle.Hub.ReviewJob.Store
  alias Tackle.Hub.Reviews.ReviewRequest
  alias Tackle.Hub.Triggers.CommandJob

  @typedoc "What an event led to, for the webhook response and logs."
  @type outcome ::
          :created
          | :rerun
          | :exists
          | :closed
          | :disabled
          | :not_automatic
          | :draft
          | :fork
          | :not_a_command
          | :bot
          | :command_queued
          | {:invalid_command, term()}

  @doc "Acts on a pull request event for `repository` (loaded with its installation)."
  @spec pull_request(Repository.t(), atom(), Tackle.Hub.Forge.pull_request(), String.t() | nil) ::
          {:ok, outcome(), ReviewRequest.t() | nil} | {:error, term()}
  def pull_request(%Repository{} = repository, :closed, pull_request, _sender) do
    with :ok <-
           ReviewRequest.skip_pending(
             repository.id,
             pull_request.number,
             nil,
             "the pull request was closed"
           ) do
      {:ok, :closed, nil}
    end
  end

  def pull_request(%Repository{} = repository, action, pull_request, sender) do
    with :ok <- check(reviewable?(repository), :disabled),
         {:ok, trigger} <- automatic_trigger(repository.auto_review, action),
         :ok <- check(not pull_request.draft or repository.auto_review_drafts, :draft),
         :ok <- check(not pull_request.head_is_fork or repository.auto_review_forks, :fork) do
      request(repository, pull_request, trigger, repository.profile, sender)
    else
      {:skip, outcome} -> {:ok, outcome, nil}
    end
  end

  defp check(true, _outcome), do: :ok
  defp check(false, outcome), do: {:skip, outcome}

  defp automatic_trigger(mode, action)
       when mode in [:on_open, :on_open_and_push] and
              action in [:opened, :reopened, :ready_for_review],
       do: {:ok, :opened}

  defp automatic_trigger(:on_open_and_push, :synchronize), do: {:ok, :pushed}
  defp automatic_trigger(_mode, _action), do: {:skip, :not_automatic}

  @doc """
  Acts on a new pull request comment: queues a `Tackle.Hub.Triggers.CommandJob`
  for a review command. Comments by bots, this app's included, never start
  a review.
  """
  @spec comment(Repository.t(), Tackle.Hub.Forge.Event.comment()) ::
          {:ok, outcome(), nil} | {:error, term()}
  def comment(%Repository{} = repository, comment) do
    case Command.parse(comment.body) do
      :none ->
        {:ok, :not_a_command, nil}

      _command when comment.author_is_bot ->
        {:ok, :bot, nil}

      {:error, reason} ->
        Logger.info("ignored a malformed review command: #{inspect(reason)}")
        {:ok, {:invalid_command, reason}, nil}

      {:review, _profile} when not repository.enabled or not repository.active ->
        {:ok, :disabled, nil}

      {:review, profile} ->
        %{
          repository_id: repository.id,
          pull_number: comment.pull_number,
          login: comment.author,
          profile: profile
        }
        |> CommandJob.new()
        |> Oban.insert()
        |> case do
          {:ok, _job} -> {:ok, :command_queued, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Runs a review command by `login` for pull request `number` of
  `repository` (loaded with its installation): checks with the forge that
  `login` has write access, reads the pull request's current head, and
  requests its review with `command/4`. `Tackle.Hub.Triggers.CommandJob`
  runs it for `/tackle review` comments, `owner_command/4` for the web
  pages.

  `{:error, :no_write_access}` and `{:error, :no_forge_app}` are final;
  other errors come from the forge and may pass on a retry.
  """
  @spec run_command(Repository.t(), pos_integer(), String.t(), atom() | nil) ::
          {:ok, outcome(), ReviewRequest.t() | nil}
          | {:error, :no_write_access | :no_forge_app | term()}
  def run_command(%Repository{} = repository, number, login, profile)
      when is_integer(number) and number > 0 and is_binary(login) do
    forge = Forge.module(repository.installation.forge)

    with {:ok, forge_app} <- forge_app(repository.installation.forge),
         {:ok, true} <- forge.can_trigger?(forge_app, repository.installation, repository, login),
         {:ok, pull_request} <-
           forge.pull_request(forge_app, repository.installation, repository, number) do
      command(repository, pull_request, profile, login)
    else
      {:ok, false} -> {:error, :no_write_access}
      {:error, reason} -> {:error, reason}
    end
  end

  defp forge_app(forge) do
    case ForgeApp.get(forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:error, :no_forge_app}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a review command from the web pages: as `run_command/4` with
  `user`'s login, for the owner of the repository's installation only
  (`{:error, :not_owner}` otherwise), since people given access may only
  read. The forge still checks the owner's write access.
  """
  @spec owner_command(User.t(), Repository.t(), pos_integer(), atom() | nil) ::
          {:ok, outcome(), ReviewRequest.t() | nil}
          | {:error, :not_owner | :no_write_access | :no_forge_app | term()}
  def owner_command(%User{} = user, %Repository{} = repository, number, profile) do
    if Installation.owned_by?(repository.installation, user),
      do: run_command(repository, number, user.login, profile),
      else: {:error, :not_owner}
  end

  @doc """
  Requests a review of `pull_request`'s head for a command by `login`, after
  its permission was checked. `profile` nil means the repository's.
  """
  @spec command(Repository.t(), Tackle.Hub.Forge.pull_request(), atom() | nil, String.t()) ::
          {:ok, outcome(), ReviewRequest.t() | nil} | {:error, term()}
  def command(%Repository{} = repository, pull_request, profile, login) do
    cond do
      not reviewable?(repository) -> {:ok, :disabled, nil}
      pull_request.state == :closed -> {:ok, :closed, nil}
      true -> request(repository, pull_request, :command, profile || repository.profile, login)
    end
  end

  defp reviewable?(repository), do: repository.enabled and repository.active

  defp request(repository, pull_request, trigger, profile, requested_by) do
    Ash.transact(ReviewRequest, fn ->
      with {:ok, outcome, request} <-
             upsert(repository, pull_request, trigger, profile, requested_by),
           :ok <- supersede(outcome, repository, pull_request),
           {:ok, _job} <- enqueue(request) do
        {outcome, request}
      end
    end)
    |> case do
      {:ok, {outcome, request}} -> {:ok, outcome, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue(%{status: status} = request) when status in [:pending, :running],
    do: {:ok, AshOban.run_trigger(request, :run)}

  defp enqueue(_request), do: {:ok, nil}

  defp upsert(repository, pull_request, trigger, profile, requested_by) do
    case ReviewRequest.get_head(repository.id, pull_request.number, pull_request.head_sha) do
      {:ok, nil} ->
        create(repository, pull_request, trigger, profile, requested_by)

      {:ok, existing} ->
        cond do
          retry_posting?(existing, trigger, profile) ->
            retry_posting(existing)

          rerun?(existing, trigger, profile) ->
            rerun(existing, trigger, profile, requested_by)

          true ->
            {:ok, :exists, existing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rerun(request, trigger, profile, requested_by) do
    attributes = %{trigger: trigger, profile: profile, requested_by: requested_by}

    with {:ok, request} <- ReviewRequest.rerun(request, attributes),
         do: {:ok, :rerun, request}
  end

  defp create(repository, pull_request, trigger, profile, requested_by) do
    attributes = %{
      repository_id: repository.id,
      pull_number: pull_request.number,
      head_sha: pull_request.head_sha,
      base_sha: pull_request.base_sha,
      base_ref: pull_request.base_ref,
      head_is_fork: pull_request.head_is_fork,
      title: Map.get(pull_request, :title),
      trigger: trigger,
      profile: profile,
      requested_by: requested_by
    }

    with {:ok, request} <- ReviewRequest.request(attributes), do: {:ok, :created, request}
  end

  defp retry_posting(existing) do
    with {:ok, request} <- Posting.retry(existing.id), do: {:ok, :exists, request}
  end

  defp retry_posting?(%{status: :failed, profile: profile, error: error}, :command, profile),
    do: error == Store.posting_error()

  defp retry_posting?(_request, _trigger, _profile), do: false

  defp rerun?(%{status: status}, :command, _profile) when status in [:failed, :skipped], do: true

  defp rerun?(%{status: status, profile: used}, :command, profile)
       when status in [:reviewed, :posted], do: used != profile

  defp rerun?(%{status: :skipped}, _automatic, _profile), do: true
  defp rerun?(_request, _trigger, _profile), do: false

  defp supersede(outcome, repository, pull_request) when outcome in [:created, :rerun] do
    ReviewRequest.skip_pending(
      repository.id,
      pull_request.number,
      pull_request.head_sha,
      "superseded by #{String.slice(pull_request.head_sha, 0, 12)}"
    )
  end

  defp supersede(:exists, _repository, _pull_request), do: :ok
end
