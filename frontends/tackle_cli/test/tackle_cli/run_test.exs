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

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
