defmodule Tackle.Hub.Checkout do
  @moduledoc """
  Full-history shared bare repositories and per-request detached worktrees.

  `prepare/1` loads the repository, installation and forge app from Ash. The
  returned handle contains only paths and IDs, never authentication material.
  Call `cleanup/1` after stopping all agents and the jail, in an `after` block.
  Keep the preparing process alive until cleanup: its global lease protects
  the worktree from `sweep/0`, including on other connected nodes.

  `sweep/0` removes only our recorded, abandoned checkouts. It fails closed on
  database errors, and preserves everything while *any* reviews-queue Oban job
  is executing (a running request status alone does not imply a live job).
  It never deletes unknown worktrees or shared clones. Call before starting
  review consumers. Busy repository locks are skipped and retried by the
  lifecycle sweeper; its Git lock wait is capped at 250 milliseconds.

  The optional options on these APIs are trusted host test seams, not request
  parameters: `:state_dir`, `:git`, `:timeout`, `:lock_timeout` (120 seconds
  by default, bounding prepare/cleanup lock acquisition), `:load` (repository loader),
  `:clone_auth` (forge callback), and `:executing?` (sweep liveness check).
  """

  import Ecto.Query, only: [from: 2]

  alias Tackle.Hub.Checkout.Git
  alias Tackle.Hub.Forge
  alias Tackle.Hub.Forge.GitHub
  alias Tackle.Hub.Forges.{ForgeApp, Repository}
  alias Tackle.Hub.Repo

  @type handle :: %{
          worktree: String.t(),
          clone: String.t(),
          state_dir: String.t(),
          request_id: String.t(),
          repository_id: String.t(),
          installation_id: String.t()
        }

  @spec prepare(map(), keyword()) :: {:ok, handle()} | {:error, atom()}
  def prepare(request, opts \\ []), do: safely(fn -> do_prepare(request, opts) end)

  defp do_prepare(request, opts) do
    with :ok <- validate_request(request),
         {:ok, repo} <- load(request.repository_id, opts),
         :ok <- validate_repo(repo, request.repository_id),
         {:ok, handle} <- paths(request.id, repo.id, repo.installation.id, opts),
         :ok <- directories(handle) do
      locked(handle, opts, fn -> prepare_leased(request, repo, handle, git_opts(handle, opts)) end)
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkout_request}
    end
  end

  defp prepare_leased(request, repo, handle, opts) do
    case :global.register_name(lease(handle), self()) do
      :yes ->
        result = safely(fn -> prepare_locked(request, repo, handle, opts) end)
        if match?({:error, _}, result), do: :global.unregister_name(lease(handle))
        result

      :no ->
        {:error, :checkout_in_use}
    end
  end

  @spec cleanup(handle(), keyword()) :: :ok | {:error, atom()}
  def cleanup(handle, opts \\ []), do: safely(fn -> do_cleanup(handle, opts) end)

  defp do_cleanup(handle, opts) do
    with {:ok, expected} <-
           paths(
             handle.request_id,
             handle.repository_id,
             handle.installation_id,
             Keyword.put(opts, :state_dir, handle.state_dir)
           ),
         true <- expected == handle,
         :ok <- directories(handle) do
      locked(handle, opts, fn -> cleanup_owned(handle, git_opts(handle, opts)) end)
    else
      _invalid -> {:error, :invalid_checkout_handle}
    end
  end

  defp cleanup_owned(handle, opts) do
    case :global.whereis_name(lease(handle)) do
      pid when is_pid(pid) and pid != self() -> {:error, :checkout_in_use}
      _none_or_owner -> remove(handle, opts)
    end
  end

  @spec sweep(keyword()) :: :ok | {:error, atom()}
  def sweep(opts \\ []), do: safely(fn -> do_sweep(opts) end)

  defp do_sweep(opts) do
    with {:ok, state} <- state_dir(opts),
         :ok <- mkdir(Path.join(state, "checkouts")),
         {:ok, names} <- File.ls(Path.join(state, "checkouts")) do
      each(names, &sweep_one(state, &1, opts))
    else
      _error -> {:error, :checkout_sweep_failed}
    end
  end

  defp sweep_one(state, name, opts) do
    # No manifest means no authority to delete anything. Never follow links.
    path = Path.join([state, "checkouts", name])

    with true <- uuid?(name),
         {:ok, %{type: :regular, size: size}} when size < 4096 <- File.lstat(path),
         {:ok, data} <- File.read(path),
         {:ok, %{"repository_id" => repo, "installation_id" => installation}} <- JSON.decode(data),
         {:ok, handle} <- paths(name, repo, installation, Keyword.put(opts, :state_dir, state)),
         :ok <- directories(handle) do
      sweep_locked(handle, opts, fn bounded_opts -> sweep_abandoned(handle, bounded_opts) end)
    else
      _unknown -> :ok
    end
  end

  defp sweep_abandoned(handle, opts) do
    executing? = Keyword.get(opts, :executing?, &executing?/0)

    if :global.whereis_name(lease(handle)) == :undefined and not executing?.(),
      do: remove(handle, git_opts(handle, opts)),
      else: :ok
  end

  defp executing? do
    Repo.exists?(
      from job in Oban.Job,
        where: job.queue == "reviews" and job.state == "executing"
    )
  end

  defp prepare_locked(request, repo, handle, opts) do
    with :ok <- recover(handle, opts),
         false <- File.exists?(handle.worktree),
         {:ok, auth} <- auth(repo, opts),
         {:ok, canonical} <- GitHub.clone_url(repo),
         true <- auth.url == canonical,
         true <-
           is_binary(auth.authorization) and
             not String.contains?(auth.authorization, ["\r", "\n", <<0>>]),
         :ok <- clone(handle, auth, opts),
         :ok <- fetch(request, handle, auth, opts),
         :ok <- ensure_commit(handle, request.base_sha, auth, opts),
         :ok <- ensure_commit(handle, request.head_sha, auth, opts),
         :ok <- record(handle) do
      case git(handle, ["worktree", "add", "--detach", handle.worktree, request.head_sha], opts) do
        :ok ->
          {:ok, handle}

        error ->
          remove(handle, opts)
          error
      end
    else
      true -> {:error, :checkout_exists}
      false -> {:error, :invalid_clone_auth}
      {:error, _reason} = error -> error
      _other -> {:error, :checkout_failed}
    end
  end

  # A killed clone can leave arbitrary partial metadata. Only publish a complete
  # bare clone; never replace an existing cache (it may own live worktrees).
  defp clone(handle, auth, opts) do
    if File.dir?(handle.clone) do
      if File.exists?(Path.join(handle.clone, "shallow")),
        do: {:error, :shallow_checkout},
        else: validate_clone(handle.clone, opts)
    else
      stage = handle.clone <> ".staging"

      with :ok <- Git.run(["clone", "--bare", "--", auth.url, stage], auth_env(auth), opts),
           :ok <- validate_clone(stage, opts),
           :ok <- File.rename(stage, handle.clone) do
        :ok
      else
        error ->
          File.rm_rf(stage)
          error
      end
    end
  end

  defp validate_clone(path, opts) do
    Git.run(
      ["--git-dir", path, "rev-parse", "--is-bare-repository"],
      [],
      Map.put(opts, :expected_output, "true\n")
    )
  end

  # locked/3 first waits for the OS lock: an old owner's Git and its helpers
  # must be gone before touching either staging data or interrupted ref locks.
  defp recover(handle, opts) do
    stage = handle.clone <> ".staging"

    with :ok <- safe_clone(handle.clone),
         :ok <- safe_clone(stage),
         {:ok, _} <- File.rm_rf(stage) do
      recover_cache(handle, opts)
    end
  end

  defp recover_cache(handle, opts) do
    if File.dir?(handle.clone) do
      case validate_clone(handle.clone, opts) do
        :ok -> remove_locks(handle.clone)
        {:error, :git_failed} -> recover_incomplete(handle)
        error -> error
      end
    else
      :ok
    end
  end

  defp recover_incomplete(handle) do
    # Upgrade recovery for clones interrupted before staging was introduced.
    # Invalid metadata alone never authorizes deleting a live worktree's clone.
    with true <- incomplete?(handle.clone),
         false <- File.exists?(Path.join(handle.clone, "worktrees")),
         {:ok, names} <- File.ls(Path.join(handle.state_dir, "checkouts")),
         false <- Enum.any?(names, &recorded_repository?(&1, handle)),
         {:ok, _} <- File.rm_rf(handle.clone) do
      :ok
    else
      _ -> {:error, :invalid_checkout_cache}
    end
  end

  defp incomplete?(clone) do
    not File.regular?(Path.join(clone, "HEAD")) or
      not File.regular?(Path.join(clone, "config")) or
      not File.dir?(Path.join(clone, "objects"))
  end

  defp recorded_repository?(name, handle) do
    with {:ok, data} <- File.read(Path.join([handle.state_dir, "checkouts", name])),
         {:ok, %{"repository_id" => repo}} <- JSON.decode(data) do
      repo == handle.repository_id
    else
      _ -> true
    end
  end

  defp remove_locks(path) do
    with {:ok, names} <- File.ls(path) do
      each(names, &remove_lock(Path.join(path, &1)))
    end
  end

  defp remove_lock(path) do
    cond do
      File.dir?(path) -> remove_locks(path)
      String.ends_with?(path, ".lock") -> File.rm(path)
      true -> :ok
    end
  end

  defp fetch(request, handle, auth, opts) do
    args = [
      "--git-dir",
      handle.clone,
      "fetch",
      "--no-auto-maintenance",
      "--no-tags",
      "--",
      auth.url
    ]

    refs = [
      "+refs/heads/#{request.base_ref}:refs/heads/#{request.base_ref}",
      "+refs/pull/#{request.pull_number}/head:refs/pull/#{request.pull_number}/head"
    ]

    case Git.run(args ++ refs, auth_env(auth), opts) do
      {:error, :git_failed} ->
        # Mutable refs may have been renamed/deleted since this request. Keep
        # requiring an authenticated fetch, but fall back to its pinned snapshot.
        Git.run(args ++ Enum.uniq([request.base_sha, request.head_sha]), auth_env(auth), opts)

      result ->
        result
    end
  end

  defp ensure_commit(handle, sha, auth, opts) do
    case verify_commit(handle, sha, opts) do
      :ok ->
        :ok

      {:error, _} ->
        with :ok <-
               Git.run(
                 [
                   "--git-dir",
                   handle.clone,
                   "fetch",
                   "--no-auto-maintenance",
                   "--no-tags",
                   "--",
                   auth.url,
                   sha
                 ],
                 auth_env(auth),
                 opts
               ) do
          verify_commit(handle, sha, opts)
        end
    end
  end

  defp verify_commit(handle, sha, opts) do
    git(
      handle,
      ["rev-parse", "--verify", sha <> "^{commit}"],
      Map.put(opts, :expected_output, sha <> "\n")
    )
  end

  defp auth_env(auth) do
    [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraHeader"},
      {"GIT_CONFIG_VALUE_0", "Authorization: " <> auth.authorization}
    ]
  end

  defp auth(repo, opts) do
    callback =
      Map.get(opts, :clone_auth, fn repo ->
        with {:ok, app} when not is_nil(app) <- ForgeApp.get(repo.installation.forge) do
          Forge.module(repo.installation.forge).clone_auth(app, repo.installation, repo)
        end
      end)

    case callback.(repo) do
      {:ok, %{url: _, authorization: _} = auth} -> {:ok, auth}
      _error -> {:error, :clone_auth_failed}
    end
  end

  defp load(id, opts) do
    loader = Keyword.get(opts, :load, fn id -> Ash.get(Repository, id, load: [:installation]) end)

    case loader.(id) do
      {:ok, repo} when not is_nil(repo) -> {:ok, repo}
      _error -> {:error, :repository_unavailable}
    end
  end

  defp record(handle) do
    data = JSON.encode!(Map.take(handle, [:repository_id, :installation_id]))

    case File.write(manifest(handle), data, [:exclusive]) do
      :ok -> :ok
      _error -> {:error, :checkout_exists}
    end
  end

  defp remove(handle, opts) do
    with :ok <- recover(handle, opts),
         {:ok, _removed} <- File.rm_rf(handle.worktree),
         :ok <- prune(handle, opts),
         :ok <- remove_manifest(handle) do
      :global.unregister_name(lease(handle))
      :ok
    else
      _error -> {:error, :checkout_cleanup_failed}
    end
  end

  defp remove_manifest(handle) do
    case File.rm(manifest(handle)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp prune(handle, opts) do
    if File.dir?(handle.clone),
      do: git(handle, ["worktree", "prune", "--expire", "now"], opts),
      else: :ok
  end

  defp git(handle, args, opts), do: Git.run(["--git-dir", handle.clone] ++ args, [], opts)
  defp lease(handle), do: {__MODULE__, :worktree, handle.request_id}
  defp manifest(handle), do: Path.join([handle.state_dir, "checkouts", handle.request_id])

  defp git_opts(handle, opts),
    do: opts |> Map.new() |> Map.put(:lock_path, handle.clone <> ".lock")

  defp locked(handle, opts, fun) do
    lock = {{__MODULE__, handle.repository_id}, self()}
    nodes = [node() | Node.list()]
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :lock_timeout, 120_000)

    with :ok <- acquire_lock(lock, nodes, deadline) do
      try do
        after_git_stops(handle, opts, fun)
      after
        :global.del_lock(lock, nodes)
      end
    end
  end

  defp acquire_lock(lock, nodes, deadline) do
    if :global.set_lock(lock, nodes, 0) do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(remaining, 25))
        acquire_lock(lock, nodes, deadline)
      else
        {:error, :checkout_lock_timeout}
      end
    end
  end

  # Startup/periodic maintenance must not queue behind a live mutation on
  # another node (or its cancellation guardian's OS lock). Busy means deferred.
  defp sweep_locked(handle, opts, fun) do
    lock = {{__MODULE__, handle.repository_id}, self()}
    nodes = [node() | Node.list()]
    opts = Keyword.put(opts, :timeout, min(Keyword.get(opts, :timeout, 250), 250))

    if :global.set_lock(lock, nodes, 0) do
      try do
        case after_git_stops(handle, opts, fn -> fun.(opts) end) do
          {:error, :git_timeout} -> :ok
          result -> result
        end
      after
        :global.del_lock(lock, nodes)
      end
    else
      :ok
    end
  end

  defp after_git_stops(handle, opts, fun) do
    with :ok <- no_links(handle.clone <> ".lock"),
         :ok <- Git.sync(git_opts(handle, opts)) do
      fun.()
    end
  end

  defp validate_request(r) do
    if is_map(r) and uuid?(Map.get(r, :id)) and uuid?(Map.get(r, :repository_id)) and
         sha?(Map.get(r, :base_sha)) and sha?(Map.get(r, :head_sha)) and
         ref?(Map.get(r, :base_ref)) and
         positive?(Map.get(r, :pull_number)) and
         is_boolean(Map.get(r, :head_is_fork)), do: :ok, else: {:error, :invalid_checkout_request}
  end

  defp validate_repo(repo, id) do
    if repo.id == id and uuid?(repo.installation.id) and repo.active and
         repo.installation.status == :active and repo.installation.forge == :github,
       do: :ok,
       else: {:error, :repository_unavailable}
  end

  defp positive?(value), do: is_integer(value) and value > 0

  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp ref?(value) when is_binary(value) and byte_size(value) in 1..1024 do
    # git-check-ref-format's branch rules, without spawning Git for untrusted
    # input. Refs are argv data, never shell text; '+' and Unicode are valid.
    value != "@" and not String.starts_with?(value, "-") and
      not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[\\]/, value) and
      not String.contains?(value, ["..", "//", "@{"]) and
      Enum.all?(String.split(value, "/"), fn part ->
        part != "" and not String.starts_with?(part, ".") and
          not String.ends_with?(part, ".lock")
      end) and not String.ends_with?(value, ".")
  end

  defp ref?(_value), do: false

  defp paths(request, repo, installation, opts) do
    with true <- Enum.all?([request, repo, installation], &uuid?/1),
         {:ok, state} <- state_dir(opts) do
      {:ok,
       %{
         request_id: request,
         repository_id: repo,
         installation_id: installation,
         state_dir: state,
         clone: Path.join([state, "repos", installation, repo]),
         worktree: Path.join([state, "worktrees", request])
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_checkout_path}
    end
  end

  defp state_dir(opts) do
    state = Keyword.get(opts, :state_dir, Application.get_env(:tackle_hub, :state_dir))

    if is_binary(state) and Path.type(state) == :absolute and Path.expand(state) == state and
         state != "/" do
      case mkdir(state) do
        :ok -> {:ok, state}
        _error -> {:error, :unsafe_checkout_path}
      end
    else
      {:error, :unsafe_checkout_path}
    end
  end

  defp directories(handle) do
    Enum.reduce_while(
      [
        Path.dirname(handle.clone),
        Path.dirname(handle.worktree),
        Path.join(handle.state_dir, "checkouts")
      ],
      :ok,
      fn path, :ok ->
        case mkdir(path) do
          :ok -> {:cont, :ok}
          _error -> {:halt, {:error, :unsafe_checkout_path}}
        end
      end
    )
    |> case do
      :ok -> no_links(handle.worktree)
      error -> error
    end
  end

  # Check ancestors before mkdir, not after following a planted symlink.
  defp mkdir("/"), do: :ok

  defp mkdir(path) do
    with :ok <- mkdir(Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          :ok

        {:error, :enoent} ->
          create_directory(path)

        _other ->
          {:error, :unsafe_checkout_path}
      end
    end
  end

  defp create_directory(path) do
    case File.mkdir(path) do
      {:error, :eexist} -> mkdir(path)
      result -> result
    end
  end

  defp no_links("/"), do: :ok

  defp no_links(path) do
    with :ok <- no_links(Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> {:error, :unsafe_checkout_path}
        {:error, :enoent} -> :ok
        {:ok, _stat} -> :ok
        _error -> {:error, :unsafe_checkout_path}
      end
    end
  end

  # Bare Git metadata is host-owned. Refuse links anywhere before invoking
  # host Git; worktree *contents* may legitimately include repository symlinks.
  defp safe_clone(path) do
    with :ok <- no_links(path) do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :directory}} ->
          safe_clone_children(path)

        {:ok, %{type: :regular}} ->
          :ok

        _other ->
          {:error, :unsafe_checkout_path}
      end
    end
  end

  defp safe_clone_children(path) do
    with {:ok, names} <- File.ls(path) do
      each(names, &safe_clone(Path.join(path, &1)))
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> {:error, :checkout_failed}
  catch
    _kind, _reason -> {:error, :checkout_failed}
  end
end
