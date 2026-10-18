defmodule Tackle.Hub.ReviewJail do
  @moduledoc """
  Owns one read-only exec jail per review. There is no local executor fallback.

  `start/1` takes a checkout with absolute `:worktree`, `:clone` (bare Git
  directory), and `:state_dir` paths. It probes every new jail before returning
  `%{client: pid, executor: executor}` (plus its private supervisor). The caller
  must `stop/1` in an `after` block, after stopping the review's agents.

  The launcher comes from `:tackle_hub, :review_jail`, configured at runtime by
  `TACKLE_HUB_REVIEW_JAIL`. Its stderr is discarded, not logged: jailed code can
  write arbitrary data there. Only PATH, HOME and locale reach the launcher;
  Bubblewrap clears the environment again before starting the exec-server.
  """

  alias Tackle.Exec.Client
  alias Tackle.Executor
  alias Tackle.Executor.Jailed

  @timeout 5_000
  @keep_env ~w(PATH HOME LANG LC_ALL)

  @type handle :: %{client: pid(), executor: Executor.t(), supervisor: pid()}

  @doc """
  Starts and verifies a dedicated jail, or returns a redacted startup error.

  The optional second argument is for trusted host tests: `:client_module`
  and `:executor_module` substitute the protocol client and jailed executor.
  Production callers should use `start/1`.
  """
  @spec start(map(), keyword()) :: {:ok, handle()} | {:error, term()}
  def start(checkout, opts \\ []) do
    with {:ok, paths} <- paths(checkout),
         {:ok, launcher} <- launcher() do
      start_client(paths, launcher, opts)
    end
  end

  @doc "Stops the client and its jail, including a jail whose probe failed. Idempotent."
  @spec stop(handle()) :: :ok | {:error, :review_jail_stop_failed}
  def stop(%{supervisor: supervisor} = handle) do
    # Forced shutdown must never kill a non-trapping, linked caller. Monitor
    # both processes: a temporary client may already have left the supervisor.
    Process.unlink(supervisor)
    pids = Enum.uniq([supervisor | List.wrap(Map.get(handle, :client))])
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})

    try do
      graceful_stop(supervisor)
      Enum.each(pids, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      deadline = System.monotonic_time(:millisecond) + @timeout

      if Enum.all?(monitors, &await_down(&1, deadline)),
        do: :ok,
        else: {:error, :review_jail_stop_failed}
    after
      Enum.each(monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    end
  end

  defp graceful_stop(supervisor) do
    # Allow the child's default five-second shutdown to finish before the
    # supervisor call times out. Any other failure still requires confirmed DOWN.
    Supervisor.stop(supervisor, :normal, @timeout + 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp await_down({pid, ref}, deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> false
    end
  end

  defp launcher do
    case Application.get_env(:tackle_hub, :review_jail) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, :review_jail_not_configured}

      _unset ->
        {:error, :review_jail_not_configured}
    end
  end

  defp start_client(paths, launcher, opts) do
    client_module = Keyword.get(opts, :client_module, Client)
    executor_module = Keyword.get(opts, :executor_module, Jailed)

    child = %{
      id: :exec,
      start:
        {client_module, :start_link,
         [[launcher: {launcher, ["/dev/null"]}, cd: paths.worktree, keep_env: @keep_env]]},
      restart: :temporary
    }

    # A failed handshake must return an error, not take the review job down
    # through a direct link. Never restart a client without re-probing it.
    case Supervisor.start_link([], strategy: :one_for_one) do
      {:ok, supervisor} -> start_child(supervisor, child, executor_module, paths)
      {:error, _reason} -> {:error, {:review_jail_failed, :startup}}
    end
  end

  defp start_child(supervisor, child, executor_module, paths) do
    case bounded_start_child(supervisor, child) do
      {:ok, client} ->
        handle = %{
          client: client,
          executor: executor_module.new(client, workspace: paths.worktree),
          supervisor: supervisor
        }

        verify_or_stop(handle, paths)

      {:error, _reason} ->
        stop(%{supervisor: supervisor})
        {:error, {:review_jail_failed, :startup}}
    end
  end

  # Supervisor.start_child itself has no deadline. Keep its supervisor handle
  # before waiting, so even an initialization that never returns is torn down.
  defp bounded_start_child(supervisor, child) do
    task =
      Task.async(fn ->
        try do
          Supervisor.start_child(supervisor, child)
        catch
          _kind, _reason -> {:error, :startup}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> {:error, :startup}
    end
  end

  defp verify_or_stop(handle, paths) do
    result =
      with :ok <- readonly(handle.executor, paths),
           :ok <- state_hidden(handle.executor, paths),
           :ok <- network_hidden(handle.executor, paths.worktree) do
        {:ok, handle}
      end

    case result do
      {:ok, _handle} ->
        result

      {:error, _reason} ->
        stop(handle)
        result
    end
  end

  defp readonly(executor, paths) do
    dirs =
      [paths.worktree, paths.clone, paths.git_dir] ++
        Enum.map(["objects", "refs"], &Path.join(paths.clone, &1))

    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      file = Path.join(dir, ".tackle-readonly-probe-#{System.unique_integer([:positive])}")

      result =
        with {:ok, %{type: :directory}} <- Executor.stat(executor, dir),
             # Permission denial proves nothing about writable existing files.
             {:error, :erofs} <-
               Executor.write(executor, file, "", mode: :create) do
          :ok
        else
          :ok ->
            # An unsafe launcher may have allowed our exclusive-create canary.
            # Remove only that canary, never an existing repository entry.
            Executor.delete(executor, file)
            {:error, {:review_jail_failed, :writable_checkout}}

          _unexpected ->
            {:error, {:review_jail_failed, :readonly_probe}}
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  # The state root can exist as a synthetic mount ancestor. Every directory
  # outside the two mounted trees must contain only their ancestor components;
  # checking just one hidden sentinel would miss a separately leaked sibling.
  defp state_hidden(executor, paths) do
    allowed = [paths.clone, paths.worktree]
    hidden_tree(executor, paths.state_dir, allowed)
  end

  defp hidden_tree(executor, dir, allowed) do
    if dir in allowed do
      :ok
    else
      expected =
        allowed
        |> Enum.filter(&inside?(dir, &1))
        |> Enum.map(&(Path.relative_to(&1, dir) |> Path.split() |> hd()))
        |> Enum.uniq()

      with {:ok, names} <- Executor.list(executor, dir),
           true <- Enum.sort(names) == Enum.sort(expected) do
        hidden_children(executor, dir, names, allowed)
      else
        _unexpected -> {:error, {:review_jail_failed, :state_visible}}
      end
    end
  end

  defp hidden_children(executor, dir, names, allowed) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case hidden_tree(executor, Path.join(dir, name), allowed) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A real listening host socket makes this deterministic and offline. A
  # shared network namespace can connect; the private namespace cannot.
  defp network_hidden(executor, cwd) do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        try do
          {:ok, port} = :inet.port(socket)
          network_probe(executor, cwd, port)
        after
          :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        {:error, {:review_jail_failed, :network_probe}}
    end
  end

  defp network_probe(executor, cwd, port) do
    # Bash's socket redirection reports errno in the C locale. Only the
    # expected network errors prove isolation; missing /dev/tcp support,
    # descriptor exhaustion, or inability to run the probe must fail closed.
    script = """
    error=$(LC_ALL=C bash --noprofile --norc -c 'exec 3<>/dev/tcp/127.0.0.1/$1' review-connect "$1" 2>&1)
    status=$?
    if [ "$status" -eq 0 ]; then exit 1; fi
    case "$error" in
      *": Connection refused"|*": Network is unreachable") exit 0 ;;
      *) exit 2 ;;
    esac
    """

    argv = ["bash", "--noprofile", "--norc", "-c", script, "review-probe", to_string(port)]

    case Executor.exec(executor, argv, cwd: cwd) do
      {:ok, ref} -> await_probe(executor, ref, System.monotonic_time(:millisecond) + @timeout)
      _unexpected -> {:error, {:review_jail_failed, :network_probe}}
    end
  end

  defp await_probe(executor, ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Executor.await(executor, ref, remaining) do
      {:exit_status, 0} ->
        :ok

      {:data, _data} when remaining > 0 ->
        await_probe(executor, ref, deadline)

      _unexpected ->
        Executor.cancel(executor, ref)
        {:error, {:review_jail_failed, :network_probe}}
    end
  end

  defp paths(%{worktree: tree, clone: clone, state_dir: state} = checkout) do
    with true <- Enum.all?([tree, clone, state], &safe_directory?/1),
         true <- inside?(state, tree) and inside?(state, clone),
         false <- inside?(tree, clone) or inside?(clone, tree) or tree == clone,
         {:ok, "gitdir: " <> pointer} <- read_pointer(Path.join(tree, ".git")),
         git_dir = Path.expand(String.trim(pointer), tree),
         true <- Path.dirname(git_dir) == Path.join(clone, "worktrees"),
         true <- safe_directory?(git_dir) do
      {:ok, Map.put(checkout, :git_dir, git_dir)}
    else
      _invalid -> {:error, :invalid_review_checkout}
    end
  end

  defp paths(_checkout), do: {:error, :invalid_review_checkout}

  defp read_pointer(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path) do
      File.open(path, [:read, :binary], &read_pointer_data/1)
    end
  end

  defp read_pointer_data(file) do
    case IO.binread(file, 4_097) do
      pointer when is_binary(pointer) and byte_size(pointer) <= 4_096 -> pointer
      _invalid -> nil
    end
  end

  defp safe_directory?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path and path != "/" and
      File.dir?(path) and no_links?(path)
  end

  defp safe_directory?(_path), do: false

  defp no_links?("/"), do: true

  defp no_links?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> no_links?(Path.dirname(path))
      _other -> false
    end
  end

  defp inside?(dir, path), do: String.starts_with?(path, dir <> "/")
end
