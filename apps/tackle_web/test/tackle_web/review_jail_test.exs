defmodule Tackle.Web.ReviewJailTest do
  use ExUnit.Case, async: false

  alias Tackle.Web.ReviewJail

  defmodule FakeClient do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts) do
      send(Application.fetch_env!(:tackle_web, :jail_test_owner), {:client_started, self(), opts})
      {:ok, opts}
    end
  end

  defmodule HungClient do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(_opts) do
      send(Application.fetch_env!(:tackle_web, :jail_test_owner), {:client_initializing, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule SlowClient do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    @impl true
    def init(test) do
      Process.flag(:trap_exit, true)
      {:ok, test}
    end

    @impl true
    def terminate(_reason, test) do
      send(test, :slow_client_stopping)
      Process.sleep(:infinity)
    end
  end

  defmodule FakeExecutor do
    def new(client, opts), do: {__MODULE__, %{client: client, cwd: opts[:workspace]}}

    def stat(_config, _path) do
      if Application.get_env(:tackle_web, :jail_test_failure) == :not_ready,
        do: {:error, :exec_server_down},
        else: {:ok, %{type: :directory}}
    end

    def write(_config, path, "", mode: :create) do
      send(self(), {:write_probe, path})
      failure = Application.get_env(:tackle_web, :jail_test_failure)

      cond do
        is_binary(failure) and String.contains?(path, failure) -> :ok
        failure in [:eacces, :eperm] -> {:error, failure}
        true -> {:error, :erofs}
      end
    end

    def delete(_config, path) do
      send(self(), {:canary_removed, path})
      :ok
    end

    def list(%{cwd: cwd}, path) do
      state = Path.dirname(cwd)

      case path do
        ^state ->
          names = ["clone", "tree"]

          names =
            if Application.get_env(:tackle_web, :jail_test_failure) == :state,
              do: ["credentials" | names],
              else: names

          {:ok, names}
      end
    end

    def exec(_config, argv, opts) do
      send(self(), {:network_probe, argv, opts})
      {:ok, make_ref()}
    end

    def await(_config, _ref, _timeout) do
      case Application.get_env(:tackle_web, :jail_test_failure) do
        :network -> {:exit_status, 1}
        :timeout -> :timeout
        :down -> {:error, :exec_server_down}
        _none -> {:exit_status, 0}
      end
    end

    def cancel(_config, _ref), do: :ok
  end

  setup do
    old = Application.get_env(:tackle_web, :review_jail)
    Application.put_env(:tackle_web, :review_jail, "/fake/review-jail")
    Application.put_env(:tackle_web, :jail_test_owner, self())
    Application.delete_env(:tackle_web, :jail_test_failure)
    root = Path.join(System.tmp_dir!(), "review-jail-#{System.unique_integer([:positive])}")
    clone = Path.join(root, "clone")
    tree = Path.join(root, "tree")
    git_dir = Path.join(clone, "worktrees/tree")
    File.mkdir_p!(git_dir)
    File.mkdir_p!(tree)
    File.write!(Path.join(tree, ".git"), "gitdir: #{git_dir}\n")

    on_exit(fn ->
      Application.put_env(:tackle_web, :review_jail, old)
      Application.delete_env(:tackle_web, :jail_test_owner)
      Application.delete_env(:tackle_web, :jail_test_failure)
      File.rm_rf!(root)
    end)

    %{checkout: %{worktree: tree, clone: clone, state_dir: root}}
  end

  defp start(checkout) do
    ReviewJail.start(checkout, client_module: FakeClient, executor_module: FakeExecutor)
  end

  test "dedicated clients, sanitized launcher environment, probes and idempotent stop", %{
    checkout: checkout
  } do
    assert {:ok, first} = start(checkout)
    assert {:ok, second} = start(checkout)
    assert first.client != second.client
    assert_receive {:client_started, client, opts}
    assert client == first.client
    assert opts[:cd] == checkout.worktree
    assert opts[:launcher] == {"/fake/review-jail", ["/dev/null"]}
    assert opts[:keep_env] == ~w(PATH HOME LANG LC_ALL)
    assert_receive {:network_probe, ["bash" | _argv], [cwd: _cwd]}
    assert :ok = ReviewJail.stop(first)
    refute Process.alive?(first.client)
    assert :ok = ReviewJail.stop(first)
    assert :ok = ReviewJail.stop(second)
  end

  @tag timeout: 30_000
  test "stop forces slow shutdown, confirms client death, and is safe for linked callers" do
    test = self()

    for trap_exit <- [false, true] do
      {caller, ref} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, trap_exit)
          {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

          {:ok, client} =
            Supervisor.start_child(supervisor, %{
              id: :exec,
              start: {SlowClient, :start_link, [test]},
              shutdown: :infinity,
              restart: :temporary
            })

          send(test, {:slow_jail, supervisor, client})
          result = ReviewJail.stop(%{supervisor: supervisor, client: client})
          send(test, {:stopped, result, Process.alive?(supervisor), Process.alive?(client)})
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {:slow_jail, supervisor, client}

      on_exit(fn ->
        Process.exit(supervisor, :kill)
        Process.exit(client, :kill)
      end)

      assert_receive :slow_client_stopping
      assert_receive {:stopped, :ok, false, false}, 12_000
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      assert :ok = ReviewJail.stop(%{supervisor: supervisor, client: client})
    end
  end

  test "each writable checkout surface fails closed and stops its client", %{checkout: checkout} do
    for path <- [
          checkout.worktree,
          checkout.clone <> "/.",
          "/objects/",
          "/refs/",
          "/worktrees/tree/"
        ] do
      Application.put_env(:tackle_web, :jail_test_failure, path)
      assert {:error, {:review_jail_failed, :writable_checkout}} = start(checkout)
      assert_receive {:client_started, client, _opts}
      refute Process.alive?(client)
      assert_receive {:canary_removed, _path}
    end
  end

  test "visible state, network, timeout, or dead server fail closed", %{checkout: checkout} do
    for {failure, expected} <- [
          not_ready: :readonly_probe,
          eacces: :readonly_probe,
          eperm: :readonly_probe,
          state: :state_visible,
          network: :network_probe,
          timeout: :network_probe,
          down: :network_probe
        ] do
      Application.put_env(:tackle_web, :jail_test_failure, failure)
      assert {:error, {:review_jail_failed, ^expected}} = start(checkout)
      assert_receive {:client_started, client, _opts}
      refute Process.alive?(client)
    end
  end

  test "network probe rejects execution errors rather than treating every failure as isolation",
       %{checkout: checkout} do
    {:ok, handle} = start(checkout)
    on_exit(fn -> ReviewJail.stop(handle) end)
    assert_receive {:network_probe, ["bash" | args], _opts}
    bin = Path.join(checkout.state_dir, "probe-bin")
    File.mkdir_p!(bin)
    bash = System.find_executable("bash")
    replacement = Path.join(bin, "bash")

    for {error, status} <- [
          {"Connection refused", 0},
          {"Network is unreachable", 0},
          {"No such file or directory", 2},
          {"Too many open files", 2}
        ] do
      File.write!(
        replacement,
        "#!#{bash}\nprintf '%s\\n' 'review-connect: #{error}' >&2\nexit 1\n"
      )

      File.chmod!(replacement, 0o700)
      assert {"", ^status} = System.cmd(bash, args, env: [{"PATH", bin}])
    end
  end

  test "hung client initialization has a deadline and leaves no client or supervisor", %{
    checkout: checkout
  } do
    task =
      Task.async(fn ->
        ReviewJail.start(checkout, client_module: HungClient, executor_module: FakeExecutor)
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    assert_receive {:client_initializing, client}, 2_000
    on_exit(fn -> Process.exit(client, :kill) end)
    {:links, [supervisor]} = Process.info(client, :links)
    supervisor_ref = Process.monitor(supervisor)
    client_ref = Process.monitor(client)
    assert {:error, {:review_jail_failed, :startup}} = Task.await(task, 20_000)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _reason}, 1_000
    assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 1_000
  end

  test "client launch errors are redacted and returned, not linked exits", %{checkout: checkout} do
    Application.put_env(:tackle_web, :review_jail, "/nonexistent/review-jail")
    assert {:error, {:review_jail_failed, :startup}} = ReviewJail.start(checkout)
  end

  test "missing launcher never falls back to local execution", %{checkout: checkout} do
    Application.delete_env(:tackle_web, :review_jail)
    assert {:error, :review_jail_not_configured} = start(checkout)
    refute_receive {:client_started, _client, _opts}
  end

  test "rejects oversized and symlinked Git pointers before launch", %{checkout: checkout} do
    pointer = Path.join(checkout.worktree, ".git")
    original = File.read!(pointer)
    File.write!(pointer, String.duplicate("x", 4_097))
    assert {:error, :invalid_review_checkout} = start(checkout)
    File.write!(pointer <> "-real", original)
    File.rm!(pointer)
    File.ln_s!(pointer <> "-real", pointer)
    assert {:error, :invalid_review_checkout} = start(checkout)
    refute_receive {:client_started, _client, _opts}
  end

  test "rejects relative, overlapping and symlinked checkout paths", %{checkout: checkout} do
    assert {:error, :invalid_review_checkout} = start(%{checkout | worktree: "relative"})
    assert {:error, :invalid_review_checkout} = start(%{checkout | clone: checkout.state_dir})
    link = checkout.worktree <> "-link"
    File.ln_s!(checkout.worktree, link)
    assert {:error, :invalid_review_checkout} = start(%{checkout | worktree: link})
  end
end
