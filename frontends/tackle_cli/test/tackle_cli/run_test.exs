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

  defp completed_prompt?(session_id, prompt, home) do
    {:ok, session} = Tackle.inspect_session(session_id, home: home)
    Enum.any?(session.messages, &(&1["content"] == prompt))
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
