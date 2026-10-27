defmodule Tackle.CLI.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tackle.CLI.Run
  alias Tackle.CLI.Test.LegacyJournal
  alias Tackle.Lib.Message
  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal
  alias Tackle.Session.Storage

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-test"

    @impl true
    def models, do: ["echo"]

    @impl true
    def model_info(_model), do: %{context_window: 1_000, max_output_tokens: 100}

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "repaired", "tool_calls" => []},
         usage: nil,
         model: "echo"
       }}
    end
  end

  defmodule ScoutAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-scout"

    @impl true
    def models, do: ["test", "alternate"]

    @impl true
    def generate(_schema, opts) do
      send(Application.fetch_env!(:tackle_cli, :scout_test_pid), {:scout_generation, opts})
      messages = Keyword.fetch!(opts, :messages)
      scout? = String.contains?(Keyword.fetch!(opts, :system), "## Scout assignment")
      task = if scout?, do: "Inspect fixture.txt", else: "parent-only request"
      current_messages = messages |> Enum.reverse() |> Enum.take_while(&(&1.content != task))
      tool_result = Enum.find(current_messages, &(&1.role == :tool))

      data =
        cond do
          tool_result ->
            %{"content" => "Observed: #{tool_result.content}", "tool_calls" => []}

          scout? ->
            call("read", %{"path" => "fixture.txt"})

          true ->
            call("subagent", %{"profile" => "scout", "prompt" => "Inspect fixture.txt"})
        end

      {:ok, %{data: data, usage: nil, model: Keyword.fetch!(opts, :model)}}
    end

    defp call(name, args) do
      %{
        "content" => nil,
        "tool_calls" => [%{"id" => "call-#{name}", "name" => name, "arguments" => args}]
      }
    end
  end

  defmodule WorkflowAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-workflow"

    @impl true
    def models, do: ["test"]

    @impl true
    def generate(_schema, opts) do
      messages = Keyword.fetch!(opts, :messages)
      current = messages |> Enum.reverse() |> Enum.take_while(&(&1.role != :user))
      result = Enum.find(current, &(&1.role == :tool))

      data =
        if result do
          %{"content" => result.content, "tool_calls" => []}
        else
          %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "saved-workflow",
                "name" => "run_workflow",
                "arguments" => %{"workflow" => "report"}
              }
            ]
          }
        end

      {:ok, %{data: data, usage: nil, model: "test"}}
    end
  end

  defmodule AuthAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-auth"

    @impl true
    def models, do: ["auth-echo"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(opts) do
      send(self(), {:auth_login, opts})
      {:ok, %{"token" => "value"}}
    end

    @impl true
    def usage(opts) do
      send(self(), {:auth_usage, opts})
      {:ok, %{"plan" => "pro"}}
    end
  end

  defmodule KeylessAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-keyless"

    @impl true
    def models, do: ["local"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(opts), do: {:error, {:login_not_required, Keyword.fetch!(opts, :provider_id)}}

    @impl true
    def status(_opts), do: {:ok, :not_required}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-cli-run-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("TACKLE_HOME")
    previous_adapters = Application.get_env(:tackle, :adapters)

    System.put_env("TACKLE_HOME", home)
    Application.put_env(:tackle, :adapters, [Adapter])

    on_exit(fn ->
      restore_env("TACKLE_HOME", previous_home)
      restore_app_env(:tackle, :adapters, previous_adapters)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "default CLI sessions delegate, return findings, and recreate the profile on resume", %{
    home: home
  } do
    Application.put_env(:tackle, :adapters, [ScoutAdapter])
    Application.put_env(:tackle_cli, :scout_test_pid, self())
    on_exit(fn -> Application.delete_env(:tackle_cli, :scout_test_pid) end)
    File.mkdir_p!(home)
    File.write!(Path.join(home, "fixture.txt"), "scout fixture finding")

    # This test asserts an exact delegation sequence; automatic session titles
    # would interleave an extra generation call, so they are opted out here.
    File.write!(Path.join(home, "config.json"), ~s({"session_titles": false}))

    # No CLI feature flag, credentials, native terminal, or real provider calls.
    File.cd!(home, fn ->
      Enum.reduce(1..2, nil, fn attempt, resume ->
        output =
          capture_io(fn ->
            assert 0 ==
                     Run.run(%{
                       model: if(attempt == 1, do: "cli-scout/alternate", else: nil),
                       thinking: nil,
                       prompt: "parent-only request",
                       resume: resume,
                       abandon: false
                     })
          end)

        assert output =~ "scout fixture finding"
        [journal_path] = Path.wildcard(Path.join(home, "sessions/--*/*/session.dlog"))
        journal_path |> Path.dirname() |> Path.basename()
      end)
    end)

    assert_receive {:scout_generation, root_opts}
    assert Keyword.fetch!(root_opts, :system) =~ "<name>scout</name>"
    assert_receive {:scout_generation, child_opts}
    assert Keyword.fetch!(child_opts, :model) == "alternate"
    assert Keyword.fetch!(child_opts, :system) =~ "## Scout assignment"
    assert Enum.any?(child_opts[:messages], &(&1.content == "Inspect fixture.txt"))
    refute Enum.any?(child_opts[:messages], &(&1.content == "parent-only request"))
    assert_receive {:scout_generation, _child_answer}
    assert_receive {:scout_generation, _root_answer}
    assert_receive {:scout_generation, _resumed_root}
    assert_receive {:scout_generation, resumed_child}
    assert Keyword.fetch!(resumed_child, :model) == "alternate"
    assert Keyword.fetch!(resumed_child, :system) =~ "## Scout assignment"
    assert Enum.any?(resumed_child[:messages], &(&1.content == "Inspect fixture.txt"))
    refute Enum.any?(resumed_child[:messages], &(&1.role == :tool))

    [journal_path] = Path.wildcard(Path.join(home, "sessions/--*/*/session.dlog"))
    session_id = journal_path |> Path.dirname() |> Path.basename()
    assert {:ok, stored} = Tackle.inspect_session(session_id, home: home, cwd: home)
    assert stored.metadata.cwd == home

    assert Enum.any?(
             stored.messages,
             &(&1["role"] == "tool" and &1["content"] =~ "scout fixture finding")
           )
  end

  test "saved workflow loader is wired into durable sessions and rebuilt on resume", %{home: home} do
    Application.put_env(:tackle, :adapters, [WorkflowAdapter])
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.json"), ~s({"session_titles": false}))

    File.cd!(home, fn ->
      assert {:ok, path} =
               Tackle.Workflows.create("report", "return 'first saved result'", cwd: home)

      Enum.reduce(["first", "edited"], nil, fn version, resume ->
        assert :ok = Tackle.Workflows.save(path, "return '#{version} saved result'", cwd: home)

        output =
          capture_io(fn ->
            assert 0 ==
                     Run.run(%{
                       model: if(resume, do: nil, else: "cli-workflow/test"),
                       thinking: nil,
                       prompt: "Run report",
                       resume: resume,
                       abandon: false
                     })
          end)

        assert output =~ "#{version} saved result"
        [journal_path] = Path.wildcard(Path.join(home, "sessions/--*/*/session.dlog"))
        journal_path |> Path.dirname() |> Path.basename()
      end)
    end)
  end

  test "resume automatically repairs an unclean journal", %{home: home} do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link(session_id: session_id, home: home, cwd: File.cwd!())
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "before crash", ID.generate())
    assert :ok = Journal.append_message(journal, Message.user("before crash"))
    assert :ok = Journal.settle_turn(journal, "turn.completed", %{})
    GenServer.stop(journal)

    {:ok, path} = Storage.journal_path(session_id, home: home, cwd: File.cwd!())
    <<magic::binary-size(4), _status::binary-size(4), rest::binary>> = File.read!(path)
    File.write!(path, magic <> <<6, 7, 8, 9>> <> rest)

    output =
      capture_io(fn ->
        assert 0 ==
                 Run.run(%{
                   model: nil,
                   thinking: nil,
                   prompt: "after repair",
                   resume: session_id,
                   abandon: false
                 })
      end)

    assert output =~ "repaired"
    {:ok, recovery_dir} = Storage.recovery_dir(session_id, home: home, cwd: File.cwd!())
    assert File.ls!(recovery_dir) != []
  end

  test "resume continues a session an earlier version closed", %{home: home} do
    session_id =
      LegacyJournal.write_closed!(home, File.cwd!(), "cli-test/echo", "before closing", "ok")

    output =
      capture_io(fn ->
        assert 0 ==
                 Run.run(%{
                   model: nil,
                   thinking: nil,
                   prompt: "after closing",
                   resume: session_id,
                   abandon: false
                 })
      end)

    assert output =~ "repaired"
    assert completed_prompt?(session_id, "after closing", home, File.cwd!())

    {:ok, session} = Tackle.inspect_session(session_id, home: home, cwd: File.cwd!())
    assert session.status == :clean

    assert Enum.map(session.messages, & &1["content"]) == [
             "before closing",
             "ok",
             "after closing",
             "repaired"
           ]
  end

  test "resume without an id selects the newest session in the current project", %{home: home} do
    # The catalog is process-global, so start the harness before seeding for the
    # seeded commits to be indexed under this test's home.
    {:ok, _apps} = Application.ensure_all_started(:tackle)
    other = Path.join(home, "other")
    File.mkdir_p!(other)

    older = seed_session(home, "older", cwd: home)
    Process.sleep(5)
    newer = seed_session(home, "newer", cwd: home)
    Process.sleep(5)
    foreign = seed_session(home, "foreign", cwd: other)

    output =
      File.cd!(home, fn ->
        capture_io(fn ->
          assert 0 ==
                   Run.run(%{
                     model: nil,
                     thinking: nil,
                     prompt: "continued",
                     resume: :latest,
                     abandon: false
                   })
        end)
      end)

    assert output =~ "repaired"
    assert completed_prompt?(newer, "continued", home)
    refute completed_prompt?(older, "continued", home)
    refute completed_prompt?(foreign, "continued", home, other)

    denied =
      File.cd!(home, fn ->
        capture_io(:stderr, fn ->
          assert 1 ==
                   Run.run(%{
                     model: nil,
                     thinking: nil,
                     prompt: "foreign prompt",
                     resume: foreign,
                     abandon: false
                   })
        end)
      end)

    assert denied =~ "no_sessions"
    refute completed_prompt?(foreign, "foreign prompt", home, other)

    listing =
      File.cd!(home, fn ->
        capture_io(fn ->
          assert 0 ==
                   Run.sessions(%{
                     query: nil,
                     limit: nil,
                     cursor: nil,
                     format: :plain,
                     color: :never
                   })
        end)
      end)

    assert listing =~ newer
    refute listing =~ foreign

    # A flat, pre-layout session with matching metadata is not resumable either.
    legacy = seed_session(home, "flat", cwd: home)
    {:ok, flat_path} = Storage.journal_path(legacy, home: home)
    {:ok, project_path} = Storage.journal_path(legacy, home: home, cwd: home)
    File.mkdir_p!(Path.dirname(flat_path))
    File.rename!(Path.dirname(project_path), Path.dirname(flat_path))

    denied_legacy =
      File.cd!(home, fn ->
        capture_io(:stderr, fn ->
          assert 1 ==
                   Run.run(%{
                     model: nil,
                     thinking: nil,
                     prompt: "flat prompt",
                     resume: legacy,
                     abandon: false
                   })
        end)
      end)

    assert denied_legacy =~ "no_sessions"

    after_move =
      File.cd!(home, fn ->
        capture_io(fn ->
          assert 0 ==
                   Run.sessions(%{
                     query: "flat",
                     limit: nil,
                     cursor: nil,
                     format: :plain,
                     color: :never
                   })
        end)
      end)

    refute after_move =~ legacy
  end

  test "resume without an id refuses sessions from other projects or without a project", %{
    home: home
  } do
    {:ok, _apps} = Application.ensure_all_started(:tackle)
    project = Path.join(home, "project")
    File.mkdir_p!(project)
    foreign = seed_session(home, "foreign", cwd: home)
    legacy = seed_session(home, "legacy")

    output =
      File.cd!(project, fn ->
        capture_io(:stderr, fn ->
          assert 1 ==
                   Run.run(%{
                     model: nil,
                     thinking: nil,
                     prompt: "not continued",
                     resume: :latest,
                     abandon: false
                   })
        end)
      end)

    assert output =~ "no_sessions"
    refute completed_prompt?(foreign, "not continued", home)
    refute completed_prompt?(legacy, "not continued", home, nil)
  end

  test "archive and unarchive move a session out of the listing and back", %{home: home} do
    {:ok, _apps} = Application.ensure_all_started(:tackle)
    session_id = seed_session(home, "archivable", cwd: home)

    list = fn archived? ->
      File.cd!(home, fn ->
        capture_io(fn ->
          assert 0 ==
                   Run.sessions(%{
                     query: nil,
                     limit: nil,
                     cursor: nil,
                     archived: archived?,
                     format: :plain,
                     color: :never
                   })
        end)
      end)
    end

    assert list.(false) =~ session_id
    refute list.(true) =~ session_id

    archived = File.cd!(home, fn -> capture_io(fn -> assert 0 == Run.archive(session_id) end) end)
    assert archived =~ "Archived session #{session_id}"
    refute list.(false) =~ session_id
    assert list.(true) =~ session_id

    denied =
      File.cd!(home, fn ->
        capture_io(:stderr, fn ->
          assert 1 ==
                   Run.run(%{
                     model: nil,
                     thinking: nil,
                     prompt: "while archived",
                     resume: session_id,
                     abandon: false
                   })
        end)
      end)

    assert denied =~ "session #{session_id} is archived"
    assert denied =~ "tackle unarchive #{session_id}"

    again =
      File.cd!(home, fn -> capture_io(:stderr, fn -> assert 1 == Run.archive(session_id) end) end)

    assert again =~ "no session #{session_id} in this project"

    restored =
      File.cd!(home, fn -> capture_io(fn -> assert 0 == Run.unarchive(session_id) end) end)

    assert restored =~ "Restored session #{session_id}"
    assert list.(false) =~ session_id
    refute list.(true) =~ session_id
  end

  test "resume restores a compressed journal", %{home: home} do
    {:ok, _apps} = Application.ensure_all_started(:tackle)
    session_id = seed_session(home, "compressed", cwd: home)
    {:ok, path} = Storage.journal_path(session_id, home: home, cwd: home)
    assert {:ok, _plain, _compressed} = Tackle.Session.CompressedFile.compress_file(path)
    refute File.exists?(path)

    File.cd!(home, fn ->
      capture_io(fn ->
        assert 0 ==
                 Run.run(%{
                   model: nil,
                   thinking: nil,
                   prompt: "after compression",
                   resume: session_id,
                   abandon: false
                 })
      end)
    end)

    assert File.regular?(path)
    assert completed_prompt?(session_id, "after compression", home)
  end

  test "auth commands dispatch to the resolved adapter" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])
    on_exit(fn -> Tackle.Auth.delete("cli-auth") end)

    login_output =
      capture_io(fn -> assert 0 == Run.auth_login(%{provider: "cli-auth"}) end)

    assert login_output =~ "Authenticated with cli-auth."
    assert_receive {:auth_login, _opts}
    assert {:ok, %{"token" => "value"}} = Tackle.Auth.fetch("cli-auth")

    status_output =
      capture_io(fn -> assert 0 == Run.auth_status(%{provider: "cli-auth"}) end)

    assert status_output =~ "stored"

    usage_output =
      capture_io(fn -> assert 0 == Run.auth_usage(%{provider: "cli-auth"}) end)

    assert usage_output =~ "pro"
    assert_receive {:auth_usage, _opts}
  end

  test "auth status without a provider lists every configured provider" do
    Application.put_env(:tackle, :adapters, [Adapter, AuthAdapter])

    output = capture_io(fn -> assert 0 == Run.auth_status(%{provider: nil}) end)

    assert output =~ "cli-test"
    assert output =~ "cli-auth"
  end

  test "auth login --as records a named account on the adapter and stores its login" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])

    on_exit(fn ->
      Tackle.Auth.delete("cli-auth-work")
      Tackle.Auth.delete_account("cli-auth-work")
    end)

    output =
      capture_io(fn ->
        assert 0 == Run.auth_login(%{provider: "cli-auth", as: "cli-auth-work"})
      end)

    assert output =~ "Authenticated with cli-auth-work."
    assert_receive {:auth_login, opts}
    assert opts[:provider_id] == "cli-auth-work"
    assert {:ok, %{"token" => "value"}} = Tackle.Auth.fetch("cli-auth-work")
    # "cli-auth" is also the default provider's id, so it is the account's base.
    assert {:ok, %{"cli-auth-work" => %{"adapter" => "cli-auth", "base" => "cli-auth"}}} =
             Tackle.Auth.accounts()

    assert :missing == Tackle.Auth.status("cli-auth")

    status_output =
      capture_io(fn ->
        assert 0 == Run.auth_status(%{provider: nil, format: :plain})
      end)

    assert status_output =~ "cli-auth\tcli-auth\tdefault\tmissing\tyes\tyes"
    assert status_output =~ "cli-auth-work\tcli-auth\taccount\tstored\tyes\tyes"

    assert {:ok, models} = Tackle.CLI.Distribution.available_models()
    assert "cli-auth-work/auth-echo" in models
  end

  test "auth login --as rejects an invalid account name without recording it" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])

    output =
      capture_io(:stderr, fn ->
        assert 1 == Run.auth_login(%{provider: "cli-auth", as: "Bad Name"})
      end)

    assert output =~ ~s("Bad Name" is not a valid provider name.)
    refute output =~ "invalid_provider_id"
    assert {:ok, accounts} = Tackle.Auth.accounts()
    refute Map.has_key?(accounts, "Bad Name")
  end

  test "auth login --as refuses the name of a built-in provider" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])

    output =
      capture_io(:stderr, fn ->
        assert 1 == Run.auth_login(%{provider: "cli-auth", as: "cli-auth"})
      end)

    assert output =~ ~s("cli-auth" is a built-in provider)
    refute_received {:auth_login, _opts}
    assert {:ok, accounts} = Tackle.Auth.accounts()
    refute Map.has_key?(accounts, "cli-auth")
  end

  test "auth login --as refuses a name recorded for another adapter" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])
    :ok = Tackle.Auth.put_account("cli-auth-taken", %{"adapter" => "not-installed"})
    on_exit(fn -> Tackle.Auth.delete_account("cli-auth-taken") end)

    output =
      capture_io(:stderr, fn ->
        assert 1 == Run.auth_login(%{provider: "cli-auth", as: "cli-auth-taken"})
      end)

    assert output =~ ~s(The name "cli-auth-taken" already belongs to a provider or account)
    refute_received {:auth_login, _opts}
    assert {:ok, %{"cli-auth-taken" => %{"adapter" => "not-installed"}}} = Tackle.Auth.accounts()
    assert :missing == Tackle.Auth.status("cli-auth-taken")
  end

  test "auth status reports keyless providers as not requiring credentials" do
    Application.put_env(:tackle, :adapters, [KeylessAdapter])

    output =
      capture_io(fn -> assert 0 == Run.auth_status(%{provider: "cli-keyless"}) end)

    assert output =~ "not required"

    login_output =
      capture_io(:stderr, fn -> assert 1 == Run.auth_login(%{provider: "cli-keyless"}) end)

    assert login_output =~ ~s(Provider "cli-keyless" needs no login)
  end

  test "auth commands reject providers that are not configured" do
    Application.put_env(:tackle, :adapters, [Adapter])

    output =
      capture_io(:stderr, fn -> assert 1 == Run.auth_login(%{provider: "missing"}) end)

    assert output =~ ~s(Provider "missing" is not configured.)
    assert output =~ "Available providers: cli-test"
    refute output =~ "unsupported_auth_provider"

    usage_output =
      capture_io(:stderr, fn -> assert 1 == Run.auth_usage(%{provider: "missing"}) end)

    assert usage_output =~ ~s(Provider "missing" is not configured.)
    refute usage_output =~ "unsupported_auth_provider"
  end

  test "an interrupted session reports a recovery hint instead of a raw inspect", %{home: home} do
    session_id = seed_interrupted_session(home)

    output =
      capture_io(:stderr, fn ->
        assert 1 ==
                 Run.run(%{
                   model: nil,
                   thinking: nil,
                   prompt: "after crash",
                   resume: session_id,
                   abandon: false
                 })
      end)

    assert output =~ "needs a recovery decision"
    assert output =~ "call-1"
    assert output =~ "--abandon"
  end

  test "resume with abandon records the decision and continues the session", %{home: home} do
    session_id = seed_interrupted_session(home)

    output =
      capture_io(fn ->
        assert 0 ==
                 Run.run(%{
                   model: nil,
                   thinking: nil,
                   prompt: "after crash",
                   resume: session_id,
                   abandon: true
                 })
      end)

    assert output =~ "repaired"
    assert completed_prompt?(session_id, "after crash", home, File.cwd!())

    {:ok, journal} = Journal.start_link(session_id: session_id, home: home, cwd: File.cwd!())
    Process.unlink(journal)
    {:ok, projection} = Journal.projection(journal)
    GenServer.stop(journal)

    assert Enum.any?(projection.turns, fn {_turn_id, turn} -> turn.status == :abandoned end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # Seeds one stopped, cleanly settled durable session in `home`.
  defp seed_session(home, prompt, opts \\ []) do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link([session_id: session_id, home: home] ++ opts)
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, prompt, ID.generate())
    assert :ok = Journal.append_message(journal, Message.user(prompt))
    assert :ok = Journal.settle_turn(journal, "turn.completed", %{})
    GenServer.stop(journal)

    session_id
  end

  # Seeds one durable session whose journal ends with a tool start that has no
  # durable result, so resuming it requires an explicit recovery decision.
  defp seed_interrupted_session(home) do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link(session_id: session_id, home: home, cwd: File.cwd!())
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "before crash", ID.generate())
    assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "bash", arguments: %{}})
    GenServer.stop(journal)

    session_id
  end

  defp completed_prompt?(session_id, prompt, home),
    do: completed_prompt?(session_id, prompt, home, home)

  defp completed_prompt?(session_id, prompt, home, cwd) do
    {:ok, session} = Tackle.inspect_session(session_id, home: home, cwd: cwd)
    Enum.any?(session.messages, &(&1["content"] == prompt))
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
