defmodule Tackle.Web.ReviewJobTest do
  use Tackle.Web.DataCase, async: false
  use Oban.Testing, repo: Tackle.Web.Repo

  import Tackle.Web.GitHubFixtures

  alias Tackle.Executor.Jailed
  alias Tackle.Lib.Usage
  alias Tackle.Plugins.Codex
  alias Tackle.Review.{Finding, Result, Settings}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Web.{AgentBackend, Models, Repo, ReviewAdapter, ReviewJail, ReviewJob}
  alias Tackle.Web.Forges.{Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
  alias Tackle.Web.ReviewJob.{Lifecycle, Store}
  alias Tackle.Web.Reviews.Finding, as: StoredFinding
  alias Tackle.Web.Reviews.{ReviewRequest, ReviewRun}

  @moduletag :capture_log

  defmodule FakeModels do
    @moduledoc false
    def enabled_providers, do: {:ok, [ReviewAdapter]}

    def resolve_settings(_settings, profile) do
      Settings.new(
        [
          profile: profile,
          default_rules: [],
          models: [detector: "scripted/detector", verifier: "scripted/verifier"]
        ],
        [ReviewAdapter]
      )
    end
  end

  defmodule FakeCheckout do
    @moduledoc false
    def prepare(request, _opts \\ []) do
      test = :global.whereis_name({__MODULE__, request.id})
      send(test, {:prepared, self()})
      {:ok, %{worktree: request.base_ref, state_dir: Path.dirname(request.base_ref), test: test}}
    end

    def cleanup(checkout, opts \\ []) do
      send(checkout.test, {:checkout_cleaned, self()})

      case opts[:cleanup_failure] do
        :error -> {:error, "private-cleanup-sentinel"}
        :raise -> raise "private-cleanup-sentinel"
        _none -> :ok
      end
    end
  end

  defmodule FakeJail do
    @moduledoc false
    def start(checkout) do
      {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

      {:ok, client} =
        Supervisor.start_child(supervisor, %{
          id: :exec,
          start: {Agent, :start_link, [fn -> nil end]},
          restart: :temporary
        })

      send(checkout.test, {:jailed, supervisor})

      {:ok,
       %{
         supervisor: supervisor,
         client: client,
         test: checkout.test,
         executor: Jailed.new(client, workspace: checkout.worktree)
       }}
    end

    def stop(handle) do
      ReviewJail.stop(handle)
      send(handle.test, :jail_cleaned)
      :ok
    end
  end

  defmodule MissingClientJail do
    @moduledoc false
    def start(checkout) do
      {:ok, jail} = FakeJail.start(checkout)
      {:ok, Map.delete(jail, :client)}
    end

    defdelegate stop(handle), to: FakeJail
  end

  defmodule ErrorCleanupJail do
    @moduledoc false
    defdelegate start(checkout), to: FakeJail

    def stop(handle) do
      FakeJail.stop(handle)
      {:error, "private-cleanup-sentinel"}
    end
  end

  defmodule FailedJail do
    @moduledoc false
    def start(_checkout), do: {:error, {:review_jail_failed, "secret must not be exposed"}}
  end

  defmodule BlockingCheckout do
    @moduledoc false
    def prepare(request, _opts \\ []) do
      {:ok, handle} = FakeCheckout.prepare(request)
      send(handle.test, {:acquiring, self()})

      receive do
        :continue -> {:ok, handle}
      end
    end

    defdelegate cleanup(handle, opts), to: FakeCheckout
  end

  setup do
    root = Path.join(System.tmp_dir!(), "review-job-#{Ecto.UUID.generate()}")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(Path.join(worktree, "lib"))
    System.cmd("git", ["init", "-b", "main", worktree], stderr_to_stdout: true)
    git!(worktree, ["config", "user.name", "Test"])
    git!(worktree, ["config", "user.email", "test@example.test"])
    rule_path = Path.join(worktree, ".tackle/review/rules/base.md")
    File.mkdir_p!(Path.dirname(rule_path))
    File.write!(rule_path, rule("base-only", "BASE-RULE"))
    File.write!(Path.join(Path.dirname(rule_path), "invalid.md"), "not a rule")
    File.write!(Path.join(worktree, "lib/a.ex"), "defmodule A do\nend\n")
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "base"])
    base = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(rule_path, rule("head-only", "HEAD-RULE"))

    File.write!(
      Path.join(worktree, "lib/a.ex"),
      "defmodule A do\n  def g(map), do: map.key\nend\n"
    )

    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "head"])
    head = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    repository = repository!(installation!(), %{enabled: true})

    request =
      ReviewRequest.request!(%{
        repository_id: repository.id,
        pull_number: 7,
        base_sha: base,
        head_sha: head,
        base_ref: worktree,
        trigger: :command,
        profile: :default
      })

    :yes = :global.register_name({FakeCheckout, request.id}, self())

    on_exit(fn ->
      :global.unregister_name({FakeCheckout, request.id})
      File.rm_rf!(root)
    end)

    {:ok,
     request: request,
     repository: repository,
     opts: [
       models: FakeModels,
       checkout: FakeCheckout,
       jail: FakeJail,
       llm_opts: [test_pid: self(), script: &script/2]
     ]}
  end

  test "whole review stores a run, uses BASE rules and jailed context, and cleans every resource",
       c do
    job = job!()
    assert :ok = run(c, job)

    assert %{status: :reviewed, claimed_job_id: id, claimed_attempt: 1} =
             Ash.get!(ReviewRequest, c.request.id)

    assert id == job.id
    assert [stored] = Ash.read!(ReviewRun)
    assert stored.summary["verdict"] == "blocking"
    assert stored.usage["total_tokens"] > 0
    assert [_warning | _] = stored.summary["warnings"]
    assert Enum.any?(stored.summary["rules"], &(&1["id"] == "base-only"))
    refute Enum.any?(stored.summary["rules"], &(&1["id"] == "head-only"))
    assert [%{state: :shown, verdict: :confirmed, support: 1}] = Ash.read!(StoredFinding)
    assert_received {:prepared, owner}
    assert_received {:jailed, jail}
    assert_received {:checkout_cleaned, ^owner}
    assert_received :jail_cleaned
    refute Process.alive?(owner)
    refute Process.alive?(jail)
    refute_received {:model_call, _, _, %{model: "root"}}
    assert [_first_call | _] = model_calls()
    assert :ok = run(c, job)
    refute_received {:model_call, _, _, _}
    assert [_run] = Ash.read!(ReviewRun)
  end

  test "a successful review redacts provider response bodies from partial scoring failures", c do
    script = fn
      nil, opts -> script(nil, opts)
      _schema, _opts -> {:error, {:http_error, 500, "private-provider-response-sentinel"}}
    end

    opts = Keyword.put(c.opts, :llm_opts, test_pid: self(), script: script)
    assert :ok = run(%{c | opts: opts}, job!())
    assert Ash.get!(ReviewRequest, c.request.id).status == :reviewed
    assert [stored] = Ash.read!(ReviewRun)

    assert [%{"fingerprint" => _, "reason" => "review stage failed"}] =
             stored.summary["scoring_failures"]

    refute JSON.encode!(stored.summary) =~ "private-provider-response-sentinel"
  end

  test "storage keeps only shown/rejected/verified-hidden, preserves support, and normalizes nested JSON",
       c do
    job = job!()
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, job)
    shown = finding("shown")
    rejected = finding("rejected")
    hidden = finding("hidden")
    dropped = %{finding("unverified") | verdict: nil}

    result = %Result{
      blocking: [shown],
      rejected: [%{finding: rejected, evidence: "lib/a.ex:2 safe"}],
      dropped: [
        %{finding: hidden, reason: {:below_threshold, 0.8}},
        %{finding: dropped, reason: :off_diff}
      ],
      summary: %{
        verdict: :blocking,
        settings: %Settings{},
        failed_units: [%{unit: "lib/a.ex#1", reason: {:http_error, 500, "private-sentinel"}}],
        incomplete_units: [%{unit: "lib/a.ex#2", reason: %{body: "private-sentinel"}}],
        verification_failures: [
          %{fingerprint: "shown", reason: RuntimeError.exception("private-sentinel")}
        ],
        nested: {:failed, %{pid: self(), ref: make_ref()}}
      },
      usage: %Usage{total_tokens: 99, raw: %{nested: %Settings{}, unsupported: fn -> :ok end}}
    }

    assert {:ok, :ok} = Store.complete(c.request.id, job, result, 12)
    assert [run] = Ash.read!(ReviewRun)
    assert run.summary["settings"]["models"] == %{}
    refute JSON.encode!(run.summary) =~ "private-sentinel"

    assert run.summary["failed_units"] ==
             [%{"unit" => "lib/a.ex#1", "reason" => "review stage failed"}]

    assert run.usage["raw"]["unsupported"] == "[unsupported]"
    assert Store.daily_tokens(c.repository.id) == 99
    assert rows = Ash.read!(StoredFinding)
    assert Enum.sort(Enum.map(rows, & &1.state)) == [:hidden, :rejected, :shown]
    assert Enum.all?(rows, &(&1.support == 2 and &1.verdict == :confirmed))

    assert Enum.find(rows, &(&1.state == :hidden)).hidden_reason == %{
             "reason" => ["below_threshold", 0.8]
           }

    assert Enum.find(rows, &(&1.state == :rejected)).evidence == "lib/a.ex:2 safe"
    assert :ok = run(c, job)

    rerun =
      ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{
        trigger: :command,
        profile: :quiet
      })

    assert rerun.claimed_job_id == nil and rerun.claimed_attempt == nil
    assert :ok = run(%{c | request: rerun}, job!())
    assert [_first, _second] = Ash.read!(ReviewRun)
  end

  test "run plus findings plus reviewed is one transaction; stale attempts cannot write", c do
    job = job!()
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, job)
    invalid = %{finding("bad") | title: nil}

    assert_raise Ash.Error.Invalid, fn ->
      Store.complete(
        c.request.id,
        job,
        %Result{blocking: [invalid], summary: %{verdict: :blocking}},
        1
      )
    end

    assert Ash.read!(ReviewRun) == []
    assert Ash.read!(StoredFinding) == []
    assert Ash.get!(ReviewRequest, c.request.id).status == :running
    next = retry!(job)
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, next)

    assert {:ok, :stale} =
             Store.complete(c.request.id, job, %Result{summary: %{verdict: :clean}}, 1)

    assert {:ok, :ok} = Store.failed(c.request.id, job, "stale")
    assert Ash.get!(ReviewRequest, c.request.id).error == nil
  end

  test "claims reject duplicates/live foreign attempts, and allow the owning job's next attempt",
       c do
    job = job!()
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, job)
    assert {:ok, :noop} = Store.claim(c.request.id, job)
    assert {:ok, :noop} = Store.claim(c.request.id, job!())
    next = retry!(job)
    assert {:ok, {:claimed, request, _}} = Store.claim(c.request.id, next)
    assert request.claimed_attempt == 2
    assert {:ok, :noop} = Store.claim(c.request.id, job)
  end

  test "pending jobs that are not actually executing cannot claim", c do
    job = job!()
    set_job_state(job, "available")
    assert {:ok, :noop} = Store.claim(c.request.id, job)
    assert Ash.get!(ReviewRequest, c.request.id).status == :pending
  end

  test "discarded/exhausted and cancelled owners reconcile to failed without a new paid cycle",
       c do
    for state <- ["discarded", "cancelled", "completed"] do
      request =
        if state == "discarded",
          do: c.request,
          else: ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{trigger: :command})

      owner = job!(3)
      assert {:ok, {:claimed, _, _}} = Store.claim(request.id, owner)
      # Timeout/process death bypasses AshOban's on_error. A later scheduler
      # job must reconcile this owner instead of resetting the paid retry limit.
      set_job_state(owner, state)
      assert :ok = run(c, job!())
      assert %{status: :failed, error: error} = Ash.get!(ReviewRequest, request.id)
      assert error =~ "without a stored run"
      assert Ash.read!(ReviewRun) == []
      refute_received {:prepared, _}
    end
  end

  test "disabled repository, inactive installation and exhausted budget skip before checkout",
       c do
    Repository.configure!(c.repository, %{enabled: false})
    assert :ok = run(c, job!())
    assert Ash.get!(ReviewRequest, c.request.id).status == :skipped
    Repository.configure!(c.repository, %{enabled: true})
    Installation.sync!(:github, c.repository.installation.external_id, "acme", :suspended)
    ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{trigger: :command})
    assert :ok = run(c, job!())
    assert Ash.get!(ReviewRequest, c.request.id).status == :skipped
    Installation.sync!(:github, c.repository.installation.external_id, "acme", :active)
    Repository.configure!(c.repository, %{daily_token_budget: 1})
    ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{trigger: :command})
    job = job!()
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, job)

    assert {:ok, :ok} =
             Store.complete(
               c.request.id,
               job,
               %Result{summary: %{verdict: :clean}, usage: %Usage{total_tokens: 1}},
               1
             )

    ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{trigger: :command})
    assert :ok = run(c, job!())

    assert %{status: :skipped, error: "daily token budget reached"} =
             Ash.get!(ReviewRequest, c.request.id)

    refute_received {:prepared, _}
  end

  test "all terminal statuses are no-ops", c do
    for status <- [:reviewed, :posted, :failed, :skipped] do
      Repo.query!("UPDATE review_requests SET status = $1 WHERE id = $2", [
        Atom.to_string(status),
        Ecto.UUID.dump!(c.request.id)
      ])

      assert :ok = run(c, job!())
    end

    refute_received {:prepared, _}
    assert Ash.read!(ReviewRun) == []
  end

  test "normal failures retry finitely, final attempt is failed, no raw error data", c do
    opts = Keyword.put(c.opts, :models, Models)
    job = job!()
    assert {:error, message} = run(%{c | opts: opts}, job)
    assert message =~ "models are required"
    assert Ash.get!(ReviewRequest, c.request.id).status == :running
    job = retry!(retry!(job))
    assert {:error, ^message} = run(%{c | opts: opts}, job)
    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
    refute_received {:prepared, _}
  end

  test "saved defaults are revalidated against providers enabled now", c do
    provider = Provider.register!("test-codex", :codex, %{enabled: true})
    model = "test-codex/" <> hd(Codex.models())
    ReviewDefaults.configure!(%{models: %{"detector" => model, "verifier" => model}})
    Provider.configure!(provider, %{enabled: false})

    assert {:error, "review model provider is not enabled"} =
             run(%{c | opts: Keyword.put(c.opts, :models, Models)}, job!(3))

    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
    refute_received {:prepared, _}
  end

  test "a killed caller tears down its globally supervised scope, jail and checkout owner", c do
    test = self()

    script = fn _, opts ->
      send(test, {:blocked_model, self(), opts})
      receive do: (:never -> :never)
    end

    opts = Keyword.put(c.opts, :llm_opts, test_pid: self(), script: script)
    job = job!()
    caller = spawn(fn -> run(%{c | opts: opts}, job) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:prepared, owner}, 2_000
    assert_receive {:jailed, jail}, 2_000
    assert_receive {:blocked_model, model, opts}, 5_000
    # Every tool context comes from the verified jail, never Local.
    assert opts[:model] == "detector"
    state = :sys.get_state(owner)
    scope_ref = state.scope
    assert {:ok, _} = Runtime.scope_snapshot(scope_ref)
    {:ok, root} = Runtime.root_agent_ref(scope_ref)
    {:ok, agent} = Runtime.session_pid(root)

    assert %{agent_state: %{context: %{executor: {Jailed, _}}, llm: %{ref: "scripted/verifier"}}} =
             :sys.get_state(agent)

    monitor = Process.monitor(model)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000
    assert_receive :jail_cleaned, 15_000
    assert_receive {:checkout_cleaned, ^owner}, 15_000
    refute Process.alive?(jail)
    assert {:error, :scope_not_found} = Runtime.scope_snapshot(scope_ref)
  end

  test "a jail dying mid-review cannot store a successful result", c do
    opts = Keyword.put(c.opts, :llm_opts, test_pid: self(), script: &ReviewAdapter.block/2)
    job = job!(3)
    task = Task.async(fn -> run(%{c | opts: opts}, job) end)
    assert_receive {:prepared, owner}, 2_000
    assert_receive {:jailed, jail}, 2_000
    assert_receive {:model_call, _, _, _}, 5_000
    Process.exit(jail, :kill)
    assert {:error, _sanitized} = Task.await(task, 20_000)
    assert_receive {:checkout_cleaned, ^owner}, 5_000
    assert Ash.read!(ReviewRun) == []
    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
  end

  test "a temporary client dying after output was produced prevents persistence", c do
    test = self()

    script = fn schema, opts ->
      output = script(schema, opts)

      if schema do
        send(test, {:output_produced, self()})
        receive do: ({:kill_client, client} -> Process.exit(client, :kill))
      end

      output
    end

    opts = Keyword.put(c.opts, :llm_opts, test_pid: self(), script: script)
    task = Task.async(fn -> run(%{c | opts: opts}, job!(3)) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:prepared, owner}, 2_000
    assert_receive {:jailed, supervisor}, 2_000
    %{jail: %{client: client}} = :sys.get_state(owner)
    assert_receive {:output_produced, model}, 5_000
    send(model, {:kill_client, client})
    assert {:error, _sanitized} = Task.await(task, 20_000)
    assert_receive {:checkout_cleaned, ^owner}, 5_000
    refute Process.alive?(client)
    refute Process.alive?(supervisor)
    assert Ash.read!(ReviewRun) == []
  end

  test "a jail handle without its actual client fails closed", c do
    opts = Keyword.put(c.opts, :jail, MissingClientJail)
    assert {:error, "review runtime stopped"} = run(%{c | opts: opts}, job!(3))
    assert_receive {:checkout_cleaned, _owner}
    assert Ash.read!(ReviewRun) == []
    refute_received {:model_call, _, _, _}
  end

  test "client DOWN cleans resources even though its temporary supervisor stays alive", c do
    {:ok, owner} = Lifecycle.start(self(), c.opts)
    on_exit(fn -> Lifecycle.stop(owner) end)
    assert {:ok, checkout} = Lifecycle.prepare(owner, c.request)
    assert {:ok, jail} = Lifecycle.jail(owner, checkout)
    # Suspend the owner to expose the exact temporary-child failure mode.
    :sys.suspend(owner)

    try do
      Process.exit(jail.client, :kill)
      assert eventually(fn -> not Process.alive?(jail.client) end)
      assert Process.alive?(jail.supervisor)
    after
      :sys.resume(owner)
    end

    assert_receive {:checkout_cleaned, ^owner}, 2_000
    assert eventually(fn -> not Process.alive?(owner) end)
    refute Process.alive?(jail.supervisor)
  end

  test "cleanup errors and exceptions are observable, sanitized, and do not skip later stages",
       c do
    for failure <- [:error, :raise] do
      opts =
        Keyword.merge(c.opts, jail: ErrorCleanupJail, checkout_opts: [cleanup_failure: failure])

      {:ok, owner} = Lifecycle.start(self(), opts)
      assert {:ok, checkout} = Lifecycle.prepare(owner, c.request)
      assert {:ok, _jail} = Lifecycle.jail(owner, checkout)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :review_cleanup_failed} = Lifecycle.stop(owner)
        end)

      assert log =~ "Review cleanup failed at stage: jail"
      assert log =~ "Review cleanup failed at stage: checkout"
      refute log =~ "private-cleanup-sentinel"
      assert_receive :jail_cleaned
      assert_receive {:checkout_cleaned, ^owner}
      refute Process.alive?(owner)
    end
  end

  test "cleanup failure does not invalidate a persisted run or trigger another paid cycle", c do
    opts = Keyword.merge(c.opts, jail: ErrorCleanupJail, checkout_opts: [cleanup_failure: :raise])
    job = job!()
    assert :ok = run(%{c | opts: opts}, job)
    assert Ash.get!(ReviewRequest, c.request.id).status == :reviewed
    assert [_stored] = Ash.read!(ReviewRun)
    model_calls()
    assert :ok = run(%{c | opts: opts}, job)
    refute_received {:model_call, _, _, _}
  end

  test "owner has a preallocated scope reference before acquisition, including a killed caller",
       c do
    caller = spawn(fn -> receive do: (:done -> :ok) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    {:ok, owner} = Lifecycle.start(caller, c.opts)
    %{scope: ref} = :sys.get_state(owner)
    {:ok, config} = AgentBackend.config(providers: [ReviewAdapter], model: "scripted/verifier")

    spec =
      ScopeSpec.new!(
        backend: AgentBackend,
        root_spec: AgentSpec.new!(name: "root", config: config)
      )

    assert {:ok, scope} = Lifecycle.scope(owner, spec)
    assert scope.scope_ref == ref
    Process.exit(caller, :kill)
    assert eventually(fn -> not Process.alive?(owner) end)
    assert {:error, :scope_not_found} = Runtime.scope_snapshot(ref)
  end

  test "AshOban forwards the actual job context to the manual action and final error action", c do
    # No test seams: missing production models must fail before checkout.
    job = c.request |> AshOban.run_trigger(:run) |> Repo.reload!()
    job = job |> Ecto.Changeset.change(state: "executing", attempt: 3) |> Repo.update!()
    assert_raise Ash.Error.Invalid, fn -> ReviewRequest.RunWorker.perform(job) end

    assert %{status: :failed, claimed_job_id: id, claimed_attempt: 3, error: message} =
             Ash.get!(ReviewRequest, c.request.id)

    assert id == job.id
    assert message =~ "models are required"
    # Exercise run_failed directly as well; it must read changeset.context.ash_oban.job.
    request = ReviewRequest.rerun!(Ash.get!(ReviewRequest, c.request.id), %{trigger: :command})
    next = job!()
    assert {:ok, {:claimed, _, _}} = Store.claim(request.id, next)
    final = next |> Ecto.Changeset.change(attempt: 3) |> Repo.update!()
    assert {:ok, {:claimed, _, _}} = Store.claim(request.id, final)

    assert {:ok, %{status: :failed}} =
             request
             |> Ash.Changeset.for_update(:run_failed, %{error: "secret provider response"})
             |> Ash.Changeset.set_context(%{ash_oban: %{job: final}})
             |> Ash.update()

    refute Ash.get!(ReviewRequest, c.request.id).error =~ "secret"
  end

  test "failed jail tears down checkout and returns a sanitized final failure", c do
    assert {:error, "review jail verification failed"} =
             run(%{c | opts: Keyword.put(c.opts, :jail, FailedJail)}, job!(3))

    assert_receive {:prepared, owner}
    assert_receive {:checkout_cleaned, ^owner}
    refute Process.alive?(owner)
    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
    assert Ash.read!(ReviewRun) == []
  end

  test "caller death during resource acquisition cannot orphan the resource", c do
    opts = Keyword.put(c.opts, :checkout, BlockingCheckout)
    job = job!(3)
    caller = spawn(fn -> run(%{c | opts: opts}, job) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:acquiring, owner}, 2_000
    Process.exit(caller, :kill)
    send(owner, :continue)
    assert_receive {:checkout_cleaned, ^owner}, 2_000
    assert eventually(fn -> not Process.alive?(owner) end)
    # Simulate Oban recording the killed, exhausted attempt as discarded.
    set_job_state(job, "discarded")
    assert :ok = run(c, job!())
    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
    refute_received {:model_call, _, _, _}
  end

  test "budget totals include only this repository's UTC calendar day", c do
    for {tokens, offset} <- [{10, -1}, {20, 0}, {30, 1}] do
      run =
        Ash.create!(ReviewRun, %{
          request_id: c.request.id,
          summary: %{},
          usage: %{total_tokens: tokens},
          duration_ms: 1,
          verdict: :clean
        })

      Repo.query!(
        "UPDATE review_runs SET inserted_at = date_trunc('day', now() AT TIME ZONE 'UTC') + $1 * interval '1 day' WHERE id = $2",
        [offset, Ecto.UUID.dump!(run.id)]
      )
    end

    assert Store.daily_tokens(c.repository.id) == 20
    assert Store.daily_tokens(Ecto.UUID.generate()) == 0
  end

  test "missing/pruned owning job fails safely instead of creating another paid review", c do
    owner = job!(3)
    assert {:ok, {:claimed, _, _}} = Store.claim(c.request.id, owner)
    Repo.delete!(owner)
    assert :ok = run(c, job!())
    assert Ash.get!(ReviewRequest, c.request.id).status == :failed
    refute_received {:prepared, _}
  end

  test "changed invalid default model fails readably before checkout", c do
    Provider.register!("test-codex", :codex, %{enabled: true})
    # Simulate an earlier catalog/default value no longer available now.
    defaults =
      ReviewDefaults.configure!(%{
        models: %{
          "detector" => "test-codex/" <> hd(Codex.models()),
          "verifier" => "test-codex/" <> hd(Codex.models())
        }
      })

    Repo.query!(
      "UPDATE review_defaults SET models = $1 WHERE id = $2",
      [
        %{
          "detector" => "test-codex/no-longer-available",
          "verifier" => "test-codex/no-longer-available"
        },
        defaults.id
      ]
    )

    assert {:error, "review model is not available"} =
             run(%{c | opts: Keyword.put(c.opts, :models, Models)}, job!(3))

    refute_received {:prepared, _}
  end

  defp run(c, job) do
    result = ReviewJob.run(%{request_id: c.request.id, job: job, opts: c.opts})
    # Our seam-driven calls bypass AshOban. Model its final-error hook; the
    # separate RunWorker test exercises the real production callback/context.
    if match?({:error, _}, result) and job.attempt == job.max_attempts do
      {:error, message} = result
      Store.failed(c.request.id, job, message)
    end

    result
  end

  defp job!(attempt \\ 1) do
    %Oban.Job{
      worker: "Tackle.Web.Reviews.ReviewRequest.RunWorker",
      queue: "reviews",
      args: %{},
      state: "executing",
      attempt: attempt,
      max_attempts: 3,
      attempted_at: DateTime.utc_now()
    }
    |> Repo.insert!()
  end

  defp retry!(job) do
    job |> Ecto.Changeset.change(attempt: job.attempt + 1, state: "executing") |> Repo.update!()
  end

  defp set_job_state(job, state), do: job |> Ecto.Changeset.change(state: state) |> Repo.update!()

  defp finding(title) do
    %Finding{
      title: title,
      category: :correctness,
      severity: :high,
      blocking: true,
      confidence: 0.95,
      location: %{path: "lib/a.ex", side: :new, start_line: 2, end_line: 2},
      trigger: "a missing key",
      body: "raises",
      support: 2,
      verdict: :confirmed,
      fingerprint: title
    }
  end

  defp script(schema, opts) when not is_nil(schema) do
    scores =
      for [id] <-
            Regex.scan(~r/<comment id="(C\d+)"/, ReviewAdapter.prompt(opts),
              capture: :all_but_first
            ),
          do: %{"id" => id, "confidence" => 0.95}

    ReviewAdapter.response(%{"scores" => scores}, opts)
  end

  defp script(nil, opts) do
    prompt = ReviewAdapter.prompt(opts)

    cond do
      Enum.any?(opts[:messages], &(&1.role == :tool)) ->
        ReviewAdapter.block(nil, opts)

      String.starts_with?(prompt, "Verify") ->
        ReviewAdapter.report(
          "report_verdict",
          %{"finding" => "F1", "verdict" => "confirmed", "evidence" => "lib/a.ex:2 unsafe"},
          opts
        )

      String.contains?(prompt, ~s(<unit id="lib/a.ex#1">)) ->
        ReviewAdapter.report(
          "report_findings",
          %{
            "findings" => [
              %{
                "title" => "Check the key",
                "category" => "correctness",
                "severity" => "high",
                "blocking" => true,
                "confidence" => 0.8,
                "rule_id" => nil,
                "location" => %{
                  "path" => "lib/a.ex",
                  "side" => "new",
                  "start_line" => 2,
                  "end_line" => 2
                },
                "trigger" => "missing key",
                "body" => "raises",
                "suggestion" => nil
              }
            ]
          },
          opts
        )

      true ->
        ReviewAdapter.report("report_findings", %{"findings" => []}, opts)
    end
  end

  defp model_calls do
    receive do
      {:model_call, _pid, schema, opts} -> [{schema, opts} | model_calls()]
    after
      0 -> []
    end
  end

  defp rule(id, body),
    do:
      "---\nid: #{id}\ncategory: correctness\nseverity: high\napplies_to: ['lib/**/*.ex']\n---\n#{body}\n"

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
