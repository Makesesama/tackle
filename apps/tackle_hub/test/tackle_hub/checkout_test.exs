defmodule Tackle.Hub.CheckoutTest do
  use Tackle.Hub.DataCase, async: false

  import Tackle.Hub.GitHubFixtures

  alias Ecto.Adapters.SQL
  alias Tackle.Hub.Checkout
  alias Tackle.Hub.Checkout.Git
  alias Tackle.Hub.Forge.GitHub
  alias Tackle.Hub.Repo
  alias Tackle.Hub.ReviewJob.{Lifecycle, Sweeper}
  alias Tackle.Hub.Reviews.ReviewRequest

  setup do
    root = Path.join(System.tmp_dir!(), "checkout-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture = Path.join(root, "source")
    System.cmd("git", ["init", "-b", "main", fixture])
    git!(fixture, ["config", "user.email", "test@example.test"])
    git!(fixture, ["config", "user.name", "Test"])

    commits =
      for n <- 1..3 do
        File.write!(Path.join(fixture, "file"), to_string(n))
        git!(fixture, ["add", "."])
        git!(fixture, ["commit", "-m", "commit #{n}"])
        git!(fixture, ["rev-parse", "HEAD"]) |> String.trim()
      end

    [base, head, _advanced_base] = commits
    git!(fixture, ["update-ref", "refs/pull/7/head", head])
    repo = repository!(installation!())

    request = %{
      id: Ecto.UUID.generate(),
      repository_id: repo.id,
      base_sha: base,
      head_sha: head,
      base_ref: "main",
      pull_number: 7,
      head_is_fork: true
    }

    wrapper = Path.join(root, "git-wrapper")
    real_git = System.find_executable("git")
    python = System.find_executable("python3")
    # Deliberate test-only transport substitution. Production never permits file
    # remotes; use the real Git object/worktree implementation without a network.
    File.write!(wrapper, """
    #!#{python}
    import os, sys, json, time, signal
    root = #{inspect(root)}
    args = sys.argv[1:]
    with open(root + '/commands', 'a') as f:
        f.write(json.dumps({'args': args, 'env': dict(os.environ)}) + '\\n')
    for operation in ['clone', 'fetch']:
        if operation in args and os.path.exists(root + '/pause-' + operation):
            if operation == 'clone':
                os.makedirs(args[-1], exist_ok=True)
                open(args[-1] + '/partial', 'w').close()
            else:
                clone = args[args.index('--git-dir') + 1]
                open(clone + '/refs/heads/main.lock', 'w').close()
            def interrupted(_signal, _frame):
                # Model a helper still draining writes during graceful TERM.
                time.sleep(0.1)
                if operation == 'clone':
                    os.makedirs(args[-1], exist_ok=True)
                    open(args[-1] + '/partial-after-term', 'w').close()
                else:
                    open(clone + '/refs/heads/main.lock', 'w').close()
            signal.signal(signal.SIGTERM, interrupted)
            with open(root + '/paused', 'w') as f: f.write(str(os.getpid()))
            time.sleep(90)
    if 'clone' in args:
        args.insert(args.index('clone') + 1, '--no-local')
    if 'fetch' in args and os.path.exists(root + '/fail'):
        print(os.environ.get('GIT_CONFIG_VALUE_0', ''), file=sys.stderr)
        sys.exit(1)
    if 'fetch' in args:
        active = root + '/active'
        try: os.mkdir(active)
        except FileExistsError:
            open(root + '/overlap', 'w').close()
            sys.exit(1)
        time.sleep(0.08)
        os.rmdir(active)
    args = [#{inspect(fixture)} if a == 'https://github.com/acme/widgets.git' else
            'protocol.file.allow=always' if a == 'protocol.file.allow=never' else a for a in args]
    os.execv(#{inspect(real_git)}, [#{inspect(real_git)}] + args)
    """)

    File.chmod!(wrapper, 0o700)

    opts = [
      state_dir: Path.join(root, "state"),
      git: wrapper,
      clone_auth: fn _repo ->
        {:ok, %{url: "https://github.com/acme/widgets.git", authorization: "Basic test-secret"}}
      end
    ]

    {:ok, root: root, repo: repo, request: request, opts: opts, fixture: fixture}
  end

  test "lifecycle owner survives real Git port exits and retains its lease through cleanup", c do
    {:ok, owner} = Lifecycle.start(self(), checkout_opts: c.opts)
    assert {:ok, handle} = Lifecycle.prepare(owner, c.request)
    assert Process.alive?(owner)
    assert File.dir?(handle.worktree)
    assert {:error, :checkout_in_use} = Checkout.cleanup(handle, c.opts)
    Lifecycle.stop(owner)
    refute Process.alive?(owner)
    refute File.exists?(handle.worktree)
  end

  test "full history, advanced base and exact detached head; only remote commands receive auth",
       c do
    System.put_env("GIT_CONFIG_COUNT", "9")
    System.put_env("GIT_DIR", "/evil")
    System.put_env("GIT_CONFIG_PARAMETERS", "'credential.helper=evil'")
    System.put_env("GIT_SSL_CAINFO", "/evil")
    System.put_env("GIT_SSL_NO_VERIFY", "true")

    on_exit(fn ->
      System.delete_env("GIT_CONFIG_COUNT")
      System.delete_env("GIT_DIR")
      System.delete_env("GIT_CONFIG_PARAMETERS")
      System.delete_env("GIT_SSL_CAINFO")
      System.delete_env("GIT_SSL_NO_VERIFY")
    end)

    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    # Read assertions must not inherit the deliberately hostile environment.
    assert command!(handle.worktree, ["rev-parse", "HEAD"]) == c.request.head_sha <> "\n"

    assert {_output, 1} =
             System.cmd("git", ["-C", handle.worktree, "symbolic-ref", "-q", "HEAD"],
               env: [{"GIT_DIR", nil}, {"GIT_CONFIG_PARAMETERS", nil}, {"GIT_CONFIG_COUNT", nil}]
             )

    assert command!(handle.worktree, ["rev-list", "--all", "--count"]) == "3\n"
    refute File.exists?(Path.join(handle.clone, "shallow"))
    assert :ok = Checkout.cleanup(handle, c.opts)
    assert :ok = Checkout.cleanup(handle, c.opts)
    refute File.exists?(handle.worktree)

    for command <- commands(c.root) do
      refute Enum.any?(command["args"], &String.contains?(&1, "test-secret"))
      env = command["env"]
      assert env["GIT_CONFIG_NOSYSTEM"] == "1"
      assert env["GIT_CONFIG_GLOBAL"] == "/dev/null"
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      refute env["GIT_DIR"]
      refute env["GIT_CONFIG_PARAMETERS"]
      refute env["GIT_SSL_NO_VERIFY"]
      refute env["GIT_SSL_CAINFO"] == "/evil"

      if File.regular?("/etc/ssl/certs/ca-certificates.crt") do
        assert env["GIT_SSL_CAINFO"] == "/etc/ssl/certs/ca-certificates.crt"
      end

      if "clone" in command["args"] or "fetch" in command["args"] do
        assert env["GIT_CONFIG_VALUE_0"] == "Authorization: Basic test-secret"
      else
        refute env["GIT_CONFIG_VALUE_0"]
        refute env["GIT_CONFIG_COUNT"]
      end
    end

    refute File.read!(Path.join(handle.clone, "config")) =~ "test-secret"
    refute inspect(handle) =~ "test-secret"
  end

  test "fetch failures and forge exceptions are sanitized; no worktree survives", c do
    File.touch!(Path.join(c.root, "fail"))
    assert {:error, :git_failed} = Checkout.prepare(c.request, c.opts)
    refute File.exists?(Path.join([c.opts[:state_dir], "worktrees", c.request.id]))

    assert {:error, :checkout_failed} =
             Checkout.prepare(
               c.request,
               Keyword.put(c.opts, :clone_auth, fn _ -> raise "test-secret" end)
             )

    File.rm!(Path.join(c.root, "fail"))
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    assert :ok = Checkout.cleanup(handle, c.opts)
  end

  test "rejects unsafe requests, URLs and symlink components without fetching", c do
    for attrs <- [
          %{id: "../escape"},
          %{repository_id: "bad"},
          %{head_sha: "--help"},
          %{base_ref: "main:refs/evil"},
          %{base_ref: "a/../b"},
          %{base_ref: "a.lock"},
          %{base_ref: "--upload-pack=evil"},
          %{base_ref: "main\n--evil"},
          %{base_ref: "a\\b"},
          %{base_ref: "a@{b"},
          %{base_ref: "a b"},
          %{base_ref: "a[1]"},
          %{pull_number: -1}
        ] do
      assert {:error, _} = Checkout.prepare(Map.merge(c.request, attrs), c.opts)
    end

    assert {:error, :invalid_clone_auth} =
             Checkout.prepare(
               c.request,
               Keyword.put(c.opts, :clone_auth, fn _ ->
                 {:ok,
                  %{url: "https://secret@github.com/acme/widgets.git", authorization: "secret"}}
               end)
             )

    File.ln_s!(c.fixture, Path.join(c.root, "linked"))

    assert {:error, :unsafe_checkout_path} =
             Checkout.prepare(
               c.request,
               Keyword.put(c.opts, :state_dir, Path.join(c.root, "linked/state"))
             )

    refute File.exists?(Path.join(c.fixture, "state"))
    clone = Path.join([c.opts[:state_dir], "repos", c.repo.installation.id, c.repo.id])
    File.ln_s!(c.fixture, clone)
    assert {:error, :unsafe_checkout_path} = Checkout.prepare(c.request, c.opts)
    refute File.exists?(Path.join(c.root, "commands"))
  end

  test "same-repository mutations serialize while worktrees can coexist", c do
    tasks =
      for _ <- 1..4 do
        Task.async(fn ->
          request = %{c.request | id: Ecto.UUID.generate()}
          assert {:ok, h} = Checkout.prepare(request, c.opts)
          assert File.dir?(h.worktree)
          assert :ok = Checkout.cleanup(h, c.opts)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 15_000))
    refute File.exists?(Path.join(c.root, "overlap"))
  end

  test "sweep preserves live leases, executing jobs and unknown entries; removes abandoned checkout",
       c do
    assert {:ok, live} = Checkout.prepare(c.request, c.opts)
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    assert File.dir?(live.worktree)
    request = %{c.request | id: Ecto.UUID.generate()}
    task = Task.async(fn -> Checkout.prepare(request, c.opts) end)
    assert {:ok, stale} = Task.await(task)
    assert :global.whereis_name({Checkout, :worktree, request.id}) == :undefined
    unknown = Path.join([c.opts[:state_dir], "worktrees", "unknown"])
    File.mkdir!(unknown)
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> true end))
    assert File.dir?(stale.worktree)

    assert {:error, :checkout_failed} =
             Checkout.sweep(
               Keyword.put(c.opts, :executing?, fn -> raise "database unavailable" end)
             )

    assert File.dir?(stale.worktree)
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    refute File.exists?(stale.worktree)
    assert File.dir?(live.worktree)
    assert File.dir?(unknown)
    assert command!(live.worktree, ["worktree", "list", "--porcelain"]) =~ live.worktree
    refute command!(live.worktree, ["worktree", "list", "--porcelain"]) =~ stale.worktree
    assert :ok = Checkout.cleanup(live, c.opts)
  end

  test "manifest removal failure retains the lease and cleanup can retry", c do
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    manifest = Path.join([handle.state_dir, "checkouts", handle.request_id])
    data = File.read!(manifest)
    File.rm!(manifest)
    File.mkdir!(manifest)
    assert {:error, :checkout_cleanup_failed} = Checkout.cleanup(handle, c.opts)
    assert :global.whereis_name({Checkout, :worktree, handle.request_id}) == self()
    File.rmdir!(manifest)
    File.write!(manifest, data)
    assert :ok = Checkout.cleanup(handle, c.opts)
    refute File.exists?(manifest)
    assert :global.whereis_name({Checkout, :worktree, handle.request_id}) == :undefined
    assert :ok = Checkout.cleanup(handle, c.opts)
  end

  test "sweep reclaims a cleanup failure after its owner's lease disappears", c do
    {:ok, owner} = Lifecycle.start(self(), checkout_opts: c.opts)
    assert {:ok, handle} = Lifecycle.prepare(owner, c.request)
    planted = Path.join(handle.clone, "evil-link")
    File.ln_s!(c.fixture, planted)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :review_cleanup_failed} = Lifecycle.stop(owner)
      end)

    assert log =~ "Review cleanup failed at stage: checkout"
    assert File.dir?(handle.worktree)
    assert :global.whereis_name({Checkout, :worktree, handle.request_id}) == :undefined
    File.rm!(planted)
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    refute File.exists?(handle.worktree)
  end

  test "prepare and cleanup bound lock contention, including after caller death", c do
    assert {:ok, live} = Checkout.prepare(c.request, c.opts)
    test = self()

    holder =
      spawn(fn ->
        :global.trans({{Checkout, c.repo.id}, self()}, fn ->
          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive :locked
    opts = Keyword.put(c.opts, :lock_timeout, 40)
    request = %{c.request | id: Ecto.UUID.generate()}
    assert {:error, :checkout_lock_timeout} = Checkout.prepare(request, opts)
    assert {:error, :checkout_lock_timeout} = Checkout.cleanup(live, opts)
    assert File.dir?(live.worktree)

    caller =
      spawn(fn ->
        {:ok, owner} = Lifecycle.start(self(), checkout_opts: opts)
        send(test, {:owner, owner})
        receive do: (:prepare -> Lifecycle.prepare(owner, request))
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:owner, owner}
    on_exit(fn -> Process.exit(owner, :kill) end)
    monitor = Process.monitor(owner)
    send(caller, :prepare)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    assert Process.alive?(holder)
    assert :global.whereis_name({Checkout, :worktree, request.id}) == :undefined
    monitor = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert :ok = Checkout.cleanup(live, c.opts)
  end

  test "sweep skips a busy distributed repository lock and retries without deleting live work",
       c do
    assert {:ok, live} = Checkout.prepare(c.request, c.opts)
    request = %{c.request | id: Ecto.UUID.generate()}
    assert {:ok, stale} = Task.async(fn -> Checkout.prepare(request, c.opts) end) |> Task.await()
    test = self()

    holder =
      spawn(fn ->
        lock = {{Checkout, c.repo.id}, self()}

        :global.trans(lock, fn ->
          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive :locked

    sweep =
      Task.async(fn -> Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end)) end)

    assert :ok = Task.await(sweep, 1_000)
    assert Process.alive?(holder)
    assert File.dir?(live.worktree)
    assert File.dir?(stale.worktree)
    monitor = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    refute File.exists?(stale.worktree)
    assert File.dir?(live.worktree)
    assert :ok = Checkout.cleanup(live, c.opts)
  end

  test "startup sweep skips a busy repository and periodic sweep retries it", c do
    assert {:ok, stale} =
             Task.async(fn -> Checkout.prepare(c.request, c.opts) end) |> Task.await()

    old_state = Application.get_env(:tackle_hub, :state_dir)
    Application.put_env(:tackle_hub, :state_dir, c.opts[:state_dir])
    on_exit(fn -> Application.put_env(:tackle_hub, :state_dir, old_state) end)
    test = self()

    holder =
      spawn(fn ->
        :global.trans({{Checkout, c.repo.id}, self()}, fn ->
          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive :locked
    startup = Task.async(fn -> Sweeper.start_link([]) end)
    assert {:ok, sweeper} = Task.await(startup, 1_000)
    on_exit(fn -> if Process.alive?(sweeper), do: GenServer.stop(sweeper) end)
    assert Process.alive?(holder)
    assert File.dir?(stale.worktree)
    monitor = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    send(sweeper, :sweep)
    # The state request waits behind handle_info, without depending on a sleep.
    :sys.get_state(sweeper)
    refute File.exists?(stale.worktree)
  end

  test "sweep bounds waiting for a cancellation guardian's OS lock", c do
    assert {:ok, stale} =
             Task.async(fn -> Checkout.prepare(c.request, c.opts) end) |> Task.await()

    ready = Path.join(c.root, "flock-ready")
    bash = System.find_executable("bash")

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        args: [
          "-c",
          "exec 9>\"$1\"; flock -x 9; echo ready > \"$2\"; read -r _",
          "lock",
          stale.clone <> ".lock",
          ready
        ]
      ])

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    wait_file(ready)

    sweep =
      Task.async(fn -> Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end)) end)

    assert :ok = Task.await(sweep, 2_000)
    assert File.dir?(stale.worktree)
    Port.command(port, "release\n")
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    refute File.exists?(stale.worktree)
  end

  test "default sweep checks Oban execution, not request status alone", c do
    request =
      c.request
      |> Map.drop([:id])
      |> Map.merge(%{profile: :default, trigger: :command})
      |> ReviewRequest.request!()

    assert {:ok, handle} = Task.async(fn -> Checkout.prepare(request, c.opts) end) |> Task.await()

    job =
      Oban.Job.new(%{"review_request_id" => request.id},
        queue: "reviews",
        worker: "Tackle.Hub.ReviewJob"
      )
      |> Ecto.Changeset.put_change(:state, "executing")
      |> Repo.insert!()

    assert :ok = Checkout.sweep(c.opts)
    assert File.dir?(handle.worktree)
    Repo.delete!(job)

    SQL.query!(
      Repo,
      "UPDATE review_requests SET status = 'running' WHERE id = $1",
      [Ecto.UUID.dump!(request.id)]
    )

    assert :ok = Checkout.sweep(c.opts)
    refute File.exists?(handle.worktree)
  end

  test "duplicate preparation preserves the live lease; cleanup refuses planted symlinks", c do
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    assert {:error, :checkout_in_use} = Checkout.prepare(c.request, c.opts)
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    assert File.dir?(handle.worktree)
    planted = Path.join(handle.clone, "evil-link")
    File.ln_s!(c.fixture, planted)
    assert {:error, :checkout_cleanup_failed} = Checkout.cleanup(handle, c.opts)
    assert File.dir?(handle.worktree)
    File.rm!(planted)
    assert :ok = Checkout.cleanup(handle, c.opts)
    File.ln_s!(c.fixture, handle.worktree)
    assert {:error, :invalid_checkout_handle} = Checkout.cleanup(handle, c.opts)
    assert File.dir?(c.fixture)
  end

  test "prepare cannot register a lease while a sweep owns the repository lock", c do
    assert {:ok, stale} =
             Task.async(fn -> Checkout.prepare(c.request, c.opts) end) |> Task.await()

    parent = self()

    sweep =
      Task.async(fn ->
        Checkout.sweep(
          Keyword.put(c.opts, :executing?, fn ->
            send(parent, {:sweeping, self()})
            receive do: (:continue -> false)
          end)
        )
      end)

    assert_receive {:sweeping, sweeper}

    prepare =
      Task.async(fn ->
        send(parent, :preparing)
        result = Checkout.prepare(c.request, c.opts)
        send(parent, {:prepared, result})
        receive do: (:cleanup -> :ok)
        with {:ok, handle} <- result, do: Checkout.cleanup(handle, c.opts)
      end)

    assert_receive :preparing
    Process.sleep(100)
    assert :global.whereis_name({Checkout, :worktree, c.request.id}) == :undefined
    send(sweeper, :continue)
    assert :ok = Task.await(sweep)
    assert_receive {:prepared, {:ok, handle}}, 5_000
    assert handle == stale
    assert :global.whereis_name({Checkout, :worktree, c.request.id}) == prepare.pid
    assert :ok = Checkout.sweep(Keyword.put(c.opts, :executing?, fn -> false end))
    assert File.dir?(handle.worktree)
    send(prepare.pid, :cleanup)
    assert :ok = Task.await(prepare)
  end

  test "cancelled clone staging is recovered before retry", c do
    cancel_prepare(c, "clone")
    clone = Path.join([c.opts[:state_dir], "repos", c.repo.installation.id, c.repo.id])
    assert File.exists?(clone <> ".staging/partial")
    refute File.exists?(clone)
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    refute File.exists?(clone <> ".staging")
    assert_dead(Path.join(c.root, "paused"))
    assert :ok = Checkout.cleanup(handle, c.opts)
  end

  test "cancelled fetch locks are recovered without replacing a live worktree clone", c do
    {:ok, owner} = Lifecycle.start(self(), checkout_opts: c.opts)
    assert {:ok, live} = Lifecycle.prepare(owner, c.request)
    c = %{c | request: %{c.request | id: Ecto.UUID.generate()}}
    cancel_prepare(c, "fetch")
    assert File.exists?(Path.join(live.clone, "refs/heads/main.lock"))
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    refute File.exists?(Path.join(live.clone, "refs/heads/main.lock"))
    assert_dead(Path.join(c.root, "paused"))
    assert command!(live.worktree, ["rev-parse", "HEAD"]) == c.request.head_sha <> "\n"
    assert :ok = Checkout.cleanup(handle, c.opts)
    Lifecycle.stop(owner)
    refute File.exists?(live.worktree)
  end

  test "legacy incomplete clones recover, but invalid clones with worktrees are preserved", c do
    clone = Path.join([c.opts[:state_dir], "repos", c.repo.installation.id, c.repo.id])
    File.mkdir_p!(clone)
    File.touch!(Path.join(clone, "partial"))
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    File.rm!(Path.join(clone, "config"))
    File.rm!(Path.join(clone, "HEAD"))
    request = %{c.request | id: Ecto.UUID.generate()}

    assert {:error, :invalid_checkout_cache} =
             Task.async(fn -> Checkout.prepare(request, c.opts) end) |> Task.await()

    assert File.dir?(handle.worktree)
    assert File.dir?(Path.join(clone, "worktrees"))
  end

  test "missing pinned commits are fetched by SHA after non-linear force pushes", c do
    git!(c.fixture, ["checkout", "--orphan", "old-history"])
    git!(c.fixture, ["commit", "--allow-empty", "-m", "old base"])
    base = git!(c.fixture, ["rev-parse", "HEAD"]) |> String.trim()
    git!(c.fixture, ["commit", "--allow-empty", "-m", "old head"])
    head = git!(c.fixture, ["rev-parse", "HEAD"]) |> String.trim()
    git!(c.fixture, ["checkout", "main"])
    git!(c.fixture, ["branch", "-D", "old-history"])
    git!(c.fixture, ["config", "uploadpack.allowAnySHA1InWant", "true"])
    assert {:ok, handle} = Checkout.prepare(%{c.request | base_sha: base, head_sha: head}, c.opts)
    assert command!(handle.worktree, ["rev-parse", "HEAD"]) == head <> "\n"
    fetched = commands(c.root) |> Enum.filter(&("fetch" in &1["args"]))
    assert Enum.any?(fetched, &(base in &1["args"]))
    assert Enum.any?(fetched, &(head in &1["args"]))
    assert :ok = Checkout.cleanup(handle, c.opts)
  end

  test "deleted mutable refs do not prevent fetching the pinned review snapshot", c do
    git!(c.fixture, ["branch", "-m", "main", "renamed"])
    git!(c.fixture, ["update-ref", "-d", "refs/pull/7/head"])
    assert {:ok, handle} = Checkout.prepare(c.request, c.opts)
    assert command!(handle.worktree, ["rev-parse", "HEAD"]) == c.request.head_sha <> "\n"
    assert :ok = Checkout.cleanup(handle, c.opts)
  end

  test "valid Git branch names include plus signs and Unicode", c do
    for name <- ["release+fix", "版本/修复"] do
      git!(c.fixture, ["branch", name])
      request = %{c.request | id: Ecto.UUID.generate(), base_ref: name}
      assert {:ok, handle} = Checkout.prepare(request, c.opts)
      assert :ok = Checkout.cleanup(handle, c.opts)
    end
  end

  test "requested objects must exist (and be commits)", c do
    request = %{c.request | head_sha: String.duplicate("f", 40)}
    assert {:error, :git_failed} = Checkout.prepare(request, c.opts)
    blob = git!(c.fixture, ["rev-parse", "HEAD:file"]) |> String.trim()
    assert {:error, :git_failed} = Checkout.prepare(%{c.request | base_sha: blob}, c.opts)
  end

  test "timeout and caller death kill Git's whole process group", c do
    script = Path.join(c.root, "slow-git")
    pids = Path.join(c.root, "pids")

    quoted_pids = "'" <> String.replace(pids, "'", "'\\''") <> "'"

    File.write!(
      script,
      "#!#{System.find_executable("bash")}\nsleep 90 &\necho $$ $! > #{quoted_pids}\nwait\n"
    )

    File.chmod!(script, 0o700)
    assert {:error, :git_timeout} = Git.run([], [], %{git: script, timeout: 200})
    assert [_parent, _child] = File.read!(pids) |> String.split()
    assert_dead(pids)
    File.rm!(pids)
    {pid, monitor} = spawn_monitor(fn -> Git.run([], [], %{git: script, timeout: 90_000}) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    wait_pids(pids)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert_dead(pids)
  end

  test "production loader and forge callback use database records and the cached token", c do
    app = forge_app!()

    GitHub.TokenCache.put(
      {app.app_id, c.repo.installation.external_id},
      "cached-secret",
      System.os_time(:second) + 3600
    )

    assert {:ok, handle} = Checkout.prepare(c.request, Keyword.delete(c.opts, :clone_auth))
    assert :ok = Checkout.cleanup(handle, c.opts)
    remote = Enum.find(commands(c.root), &("fetch" in &1["args"]))

    assert remote["env"]["GIT_CONFIG_VALUE_0"] ==
             "Authorization: Basic " <> Base.encode64("x-access-token:cached-secret")
  end

  test "clone_auth uses installation_token and canonical HTTPS", c do
    app = forge_app!()
    key = {app.app_id, c.repo.installation.external_id}
    GitHub.TokenCache.put(key, "installation-secret", System.os_time(:second) + 3600)

    assert {:ok, %{url: "https://github.com/acme/widgets.git", authorization: auth}} =
             GitHub.clone_auth(app, c.repo.installation, c.repo)

    assert auth == "Basic " <> Base.encode64("x-access-token:installation-secret")

    for name <- [".github", ".config", "normal.repo", "-widgets"] do
      assert {:ok, "https://github.com/acme/" <> _} =
               GitHub.clone_url(%{c.repo | name: name})
    end

    for owner <- [".github", "acme/evil", "acme%2fevil", "-acme", "acme-", "a..b"] do
      assert {:error, :invalid_clone_url} = GitHub.clone_url(%{c.repo | owner: owner})
    end

    for name <- ["../evil", "x/y", "x?query", "x#fragment", "x%2fy", "x.git", "x\n"] do
      assert {:error, :invalid_clone_url} =
               GitHub.clone_auth(app, c.repo.installation, %{c.repo | name: name})
    end
  end

  defp cancel_prepare(c, operation) do
    marker = Path.join(c.root, "pause-" <> operation)
    File.touch!(marker)
    {pid, monitor} = spawn_monitor(fn -> Checkout.prepare(c.request, c.opts) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    paused = Path.join(c.root, "paused")
    wait_file(paused)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    # Retry immediately: the OS lock, not a test sleep, must wait for Git's
    # bounded TERM/KILL teardown before recovering metadata.
    File.rm!(marker)
  end

  defp commands(root),
    do:
      File.read!(Path.join(root, "commands"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

  defp git!(cwd, args), do: command!(cwd, args)

  defp command!(cwd, args) do
    {output, 0} =
      System.cmd("git", ["-C", cwd] ++ args,
        env: [{"GIT_DIR", nil}, {"GIT_CONFIG_PARAMETERS", nil}, {"GIT_CONFIG_COUNT", nil}]
      )

    output
  end

  defp wait_file(path, retries \\ 100)

  defp wait_file(path, retries) when retries > 0 do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_file(path, retries - 1)
        )
  end

  defp wait_file(_path, 0), do: flunk("subprocess did not start")

  defp wait_pids(path, retries \\ 100)
  defp wait_pids(_path, 0), do: flunk("subprocess PIDs were not published")

  defp wait_pids(path, retries) do
    case File.read(path) do
      {:ok, data} ->
        if Regex.match?(~r/\A[1-9]\d* [1-9]\d*\n\z/, data) do
          assert [_parent, _child] = String.split(data)
        else
          Process.sleep(20)
          wait_pids(path, retries - 1)
        end

      _not_ready ->
        Process.sleep(20)
        wait_pids(path, retries - 1)
    end
  end

  defp assert_dead(path, retries \\ 100) do
    pids = File.read!(path) |> String.split()

    alive =
      Enum.any?(pids, fn pid ->
        case File.read("/proc/#{pid}/stat") do
          {:ok, stat} -> not String.contains?(stat, ") Z ")
          {:error, :enoent} -> false
        end
      end)

    if alive and retries > 0 do
      Process.sleep(20)
      assert_dead(path, retries - 1)
    else
      refute alive, "Git or a helper survived cancellation"
    end
  end
end
