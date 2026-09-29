defmodule Tackle.CLI.SidebarPreferencesTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.TUI.{Menu, Preferences, State, Viewport}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.State, as: AgentState

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-sidebar-#{System.unique_integer([:positive])}")
    old_home = System.get_env("TACKLE_HOME")
    System.put_env("TACKLE_HOME", home)

    on_exit(fn ->
      if old_home,
        do: System.put_env("TACKLE_HOME", old_home),
        else: System.delete_env("TACKLE_HOME")

      File.rm_rf(home)
    end)

    %{path: Path.join(home, "config.json")}
  end

  test "defaults to visible and persists a toggle without losing existing fields", %{path: path} do
    assert {:ok, true} = Preferences.sidebar()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"model":"openai-codex/gpt-5","thinking":"high"}))

    assert :ok = Preferences.put_sidebar(false)
    assert {:ok, false} = Preferences.sidebar()

    assert {:ok,
            %{
              "model" => "openai-codex/gpt-5",
              "thinking" => "high",
              "show_subagent_sidebar" => false
            }} = path |> File.read!() |> JSON.decode()

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "invalid configuration is not overwritten", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"show_subagent_sidebar":"false"}))

    assert {:error, {:invalid_config_field, ^path, "show_subagent_sidebar"}} =
             Preferences.sidebar()

    assert {:error, {:invalid_config_field, ^path, "show_subagent_sidebar"}} =
             Preferences.put_sidebar(true)

    assert File.read!(path) == ~s({"show_subagent_sidebar":"false"})
  end

  test "F3 setting toggles immediately and persists across mounts", %{path: path} do
    state =
      Viewport.refresh(%State{
        input: Input.new(),
        agent_state: %AgentState{},
        conversation: Viewport.new_conversation(80, 24),
        tool_activity: [%{id: "one", name: "subagent", status: :running}]
      })

    assert state.conversation.rect.width < 80
    {:noreply, opened} = Menu.open(:settings, state)
    {:noreply, hidden} = Menu.handle(:accept, opened)

    refute hidden.show_subagent_sidebar?
    assert hidden.overlay == nil
    assert hidden.conversation.rect.width == 80
    assert {:ok, false} = Preferences.sidebar()
    assert {:ok, %{"show_subagent_sidebar" => false}} = path |> File.read!() |> JSON.decode()

    {:noreply, reopened} = Menu.open(:settings, hidden)
    assert [%{secondary: "Hidden"}] = Menu.items(:settings, reopened)
    {:noreply, shown} = Menu.handle(:accept, reopened)
    assert shown.show_subagent_sidebar?
    assert shown.conversation.rect.width < 80
    assert {:ok, true} = Preferences.sidebar()
  end

  test "a failed save leaves the previous visibility intact", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not JSON")

    state = %State{}
    {:noreply, opened} = Menu.open(:settings, state)
    {:noreply, unchanged} = Menu.handle(:accept, opened)

    assert unchanged.show_subagent_sidebar?
    assert unchanged.overlay == nil
    assert unchanged.notice =~ "Could not save setting"
    assert File.read!(path) == "not JSON"
  end
end
