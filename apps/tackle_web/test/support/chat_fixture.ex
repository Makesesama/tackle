defmodule Tackle.Web.ChatFixture do
  @moduledoc """
  Setup shared by the chat tests.

  A chat test needs three things every time, and all three are global
  configuration, so they have to be restored on exit:

    * a deterministic `Tackle.Lib.LLM` adapter, because a test must not need
      provider credentials or a live model;
    * a working directory that exists and can be written to, because a
      conversation is pinned to one;
    * a `TACKLE_HOME` pointing at a scratch directory, because `Tackle.Config`
      reads the harness configuration and system prompt from there and must not
      pick up the developer's own files.

  The chat tests are `async: false` precisely because of this shared
  configuration.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Tackle.Web.FakeAdapter

  @settings [:agent_adapters, :agent_model, :chat_cwd]

  @doc """
  Installs the test configuration and returns the scratch paths.

  Returns `%{root: root, cwd: cwd}`, where `root` holds everything the test
  creates and `cwd` is the directory a conversation should run in.
  """
  @spec setup() :: %{root: Path.t(), cwd: Path.t()}
  def setup do
    previous =
      Map.new(@settings, fn setting -> {setting, Application.get_env(:tackle_web, setting)} end)
      |> Map.put(:tackle_home, System.get_env("TACKLE_HOME"))

    root = Path.join(System.tmp_dir!(), "tackle_web_chat_#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)

    System.put_env("TACKLE_HOME", home)
    Application.put_env(:tackle_web, :agent_adapters, [FakeAdapter])
    Application.put_env(:tackle_web, :agent_model, "fake/echo")

    on_exit(fn ->
      Enum.each(@settings, fn setting -> restore(setting, Map.fetch!(previous, setting)) end)
      restore_home(Map.fetch!(previous, :tackle_home))
      File.rm_rf(root)
    end)

    %{root: root, cwd: cwd}
  end

  @doc "The model an overriding test should switch a conversation to."
  @spec other_model() :: String.t()
  def other_model, do: "fake/echo-2"

  defp restore(setting, nil), do: Application.delete_env(:tackle_web, setting)
  defp restore(setting, value), do: Application.put_env(:tackle_web, setting, value)

  defp restore_home(nil), do: System.delete_env("TACKLE_HOME")
  defp restore_home(home), do: System.put_env("TACKLE_HOME", home)
end
