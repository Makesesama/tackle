defmodule Tackle.CLI.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tackle.CLI.Run
  alias Tackle.Lib.Message
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

  defmodule ExplorerAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-explorer"

    @impl true
    def models, do: ["test", "alternate"]

    @impl true
    def generate(_schema, opts) do
      send(Application.fetch_env!(:tackle_cli, :explorer_test_pid), {:explorer_generation, opts})
      messages = Keyword.fetch!(opts, :messages)
      explorer? = String.contains?(Keyword.fetch!(opts, :system), "## Explorer assignment")
      task = if explorer?, do: "Inspect fixture.txt", else: "parent-only request"
      current_messages = messages |> Enum.reverse() |> Enum.take_while(&(&1.content != task))
      tool_result = Enum.find(current_messages, &(&1.role == :tool))

      data =
        cond do
          tool_result ->
            %{"content" => "Observed: #{tool_result.content}", "tool_calls" => []}

          explorer? ->
            call("read", %{"path" => "fixture.txt"})

          true ->
            call("subagent", %{"profile" => "explorer", "prompt" => "Inspect fixture.txt"})
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
    Application.put_env(:tackle, :adapters, [ExplorerAdapter])
    Application.put_env(:tackle_cli, :explorer_test_pid, self())
    on_exit(fn -> Application.delete_env(:tackle_cli, :explorer_test_pid) end)
    File.mkdir_p!(home)
    File.write!(Path.join(home, "fixture.txt"), "explorer fixture finding")

    # No CLI feature flag, credentials, native terminal, or real provider calls.
    File.cd!(home, fn ->
      Enum.reduce(1..2, nil, fn attempt, resume ->
        output =
          capture_io(fn ->
            assert 0 ==
                     Run.run(%{
                       model: if(attempt == 1, do: "cli-explorer/alternate", else: nil),
                       thinking: nil,
                       prompt: "parent-only request",
                       resume: resume,
                       abandon: false
                     })
          end)

        assert output =~ "explorer fixture finding"
        [journal_path] = Path.wildcard(Path.join(home, "sessions/*/session.dlog"))
        journal_path |> Path.dirname() |> Path.basename()
      end)
    end)

    assert_receive {:explorer_generation, root_opts}
    assert Keyword.fetch!(root_opts, :system) =~ "profile \"explorer\""
    assert_receive {:explorer_generation, child_opts}
    assert Keyword.fetch!(child_opts, :model) == "alternate"
    assert Keyword.fetch!(child_opts, :system) =~ "## Explorer assignment"
    assert Enum.any?(child_opts[:messages], &(&1.content == "Inspect fixture.txt"))
    refute Enum.any?(child_opts[:messages], &(&1.content == "parent-only request"))
    assert_receive {:explorer_generation, _child_answer}
    assert_receive {:explorer_generation, _root_answer}
    assert_receive {:explorer_generation, _resumed_root}
    assert_receive {:explorer_generation, resumed_child}
    assert Keyword.fetch!(resumed_child, :model) == "alternate"
    assert Keyword.fetch!(resumed_child, :system) =~ "## Explorer assignment"
    assert Enum.any?(resumed_child[:messages], &(&1.content == "Inspect fixture.txt"))
    refute Enum.any?(resumed_child[:messages], &(&1.role == :tool))

    [journal_path] = Path.wildcard(Path.join(home, "sessions/*/session.dlog"))
    session_id = journal_path |> Path.dirname() |> Path.basename()
    assert {:ok, stored} = Tackle.inspect_session(session_id, home: home)

    assert Enum.any?(
             stored.messages,
             &(&1["role"] == "tool" and &1["content"] =~ "explorer fixture finding")
           )
  end

  test "resume automatically repairs an unclean journal", %{home: home} do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link(session_id: session_id, home: home)
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "before crash")
    assert :ok = Journal.append_message(journal, Message.user("before crash"))
    assert :ok = Journal.settle_turn(journal, "turn.completed", %{})
    assert :ok = Journal.close_journal(journal)
    GenServer.stop(journal)

    {:ok, path} = Storage.journal_path(session_id, home: home)
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
    {:ok, recovery_dir} = Storage.recovery_dir(session_id, home: home)
    assert File.ls!(recovery_dir) != []
  end

  test "resume without an id continues the most recently updated session", %{home: home} do
    # The catalog is process-global, so start the harness before seeding for the
    # seeded commits to be indexed under this test's home.
    {:ok, _apps} = Application.ensure_all_started(:tackle)

    older = seed_session(home, "older")
    Process.sleep(5)
    newer = seed_session(home, "newer")

    output =
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

    assert output =~ "repaired"
    assert completed_prompt?(newer, "continued", home)
    refute completed_prompt?(older, "continued", home)
  end

  test "auth commands dispatch to the resolved adapter" do
    Application.put_env(:tackle, :adapters, [AuthAdapter])
    on_exit(fn -> Tackle.Auth.delete("cli-auth") end)

    login_output =
      capture_io(fn -> assert 0 == Run.auth_login(%{provider: "cli-auth"}) end)

    assert login_output =~ "Stored credentials for cli-auth."
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

  test "auth commands reject providers that are not configured" do
    Application.put_env(:tackle, :adapters, [Adapter])

    output =
      capture_io(:stderr, fn -> assert 1 == Run.auth_login(%{provider: "missing"}) end)

    assert output =~ "unsupported_auth_provider"

    usage_output =
      capture_io(:stderr, fn -> assert 1 == Run.auth_usage(%{provider: "missing"}) end)

    assert usage_output =~ "unsupported_auth_provider"
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
    assert completed_prompt?(session_id, "after crash", home)

    {:ok, journal} = Journal.start_link(session_id: session_id, home: home)
    Process.unlink(journal)
    {:ok, projection} = Journal.projection(journal)
    GenServer.stop(journal)

    assert Enum.any?(projection.turns, fn {_turn_id, turn} -> turn.status == :abandoned end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # Seeds one closed, cleanly settled durable session in `home`.
  defp seed_session(home, prompt) do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link(session_id: session_id, home: home)
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, prompt)
    assert :ok = Journal.append_message(journal, Message.user(prompt))
    assert :ok = Journal.settle_turn(journal, "turn.completed", %{})
    assert :ok = Journal.close_journal(journal)
    GenServer.stop(journal)

    session_id
  end

  # Seeds one durable session whose journal ends with a tool start that has no
  # durable result, so resuming it requires an explicit recovery decision.
  defp seed_interrupted_session(home) do
    session_id = "session-#{System.unique_integer([:positive])}"
    {:ok, journal} = Journal.start_link(session_id: session_id, home: home)
    Process.unlink(journal)

    assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "before crash")
    assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "bash", arguments: %{}})
    assert :ok = Journal.close_journal(journal)
    GenServer.stop(journal)

    session_id
  end

  defp completed_prompt?(session_id, prompt, home) do
    {:ok, session} = Tackle.inspect_session(session_id, home: home)
    Enum.any?(session.messages, &(&1["content"] == prompt))
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
