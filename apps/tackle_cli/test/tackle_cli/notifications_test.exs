defmodule Tackle.CLI.NotificationsTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Notifications

  describe "sequence/3" do
    test "BEL is a single bell byte" do
      assert Notifications.sequence("hello", :bel, false) == "\a"
      assert Notifications.sequence("hello", :bel, true) == "\a"
    end

    test "OSC 9 frames the body with a BEL terminator" do
      assert Notifications.sequence("hello", :osc9, false) == "\e]9;hello\a"
    end

    test "OSC 9 under tmux is wrapped in a DCS passthrough" do
      assert Notifications.sequence("done", :osc9, true) ==
               "\ePtmux;\e\e]9;done\a\e\\"
    end

    test "OSC 9 under tmux escapes ESC bytes in the payload" do
      assert Notifications.sequence("danger\e[31m", :osc9, true) ==
               "\ePtmux;\e\e]9;danger\e\e[31m\a\e\\"
    end
  end

  test "osc9/1 frames the body as OSC 9 with a BEL terminator" do
    assert Notifications.osc9("hello") == "\e]9;hello\a"
  end

  describe "supports_osc9?/1" do
    test "TERM_PROGRAM identifies supporting terminals" do
      for term_program <- ["ghostty", "iTerm.app", "iTerm2", "WezTerm", "WarpTerminal"] do
        assert Notifications.supports_osc9?(%{"TERM_PROGRAM" => term_program}),
               "#{term_program} should support OSC 9"
      end
    end

    test "TERM_PROGRAM identifies unsupported terminals" do
      for term_program <- ["Apple_Terminal", "vscode", "alacritty", "gnome-terminal"] do
        refute Notifications.supports_osc9?(%{"TERM_PROGRAM" => term_program}),
               "#{term_program} should not support OSC 9"
      end
    end

    test "TERM_PROGRAM naming tmux falls through to the variable probes" do
      # tmux's own TERM_PROGRAM says nothing about the outer terminal, so the
      # terminal-specific variables inherited through tmux decide.
      refute Notifications.supports_osc9?(%{"TERM_PROGRAM" => "tmux"})

      assert Notifications.supports_osc9?(%{
               "TERM_PROGRAM" => "tmux",
               "GHOSTTY_RESOURCES_DIR" => "/x"
             })
    end

    test "terminal-specific variables detect the outer terminal without TERM_PROGRAM" do
      assert Notifications.supports_osc9?(%{"GHOSTTY_RESOURCES_DIR" => "/opt/ghostty"})
      assert Notifications.supports_osc9?(%{"WEZTERM_VERSION" => "20240203"})
      assert Notifications.supports_osc9?(%{"ITERM_SESSION_ID" => "w0t0p0"})
      assert Notifications.supports_osc9?(%{"ITERM_PROFILE" => "Default"})
      assert Notifications.supports_osc9?(%{"ITERM_PROFILE_NAME" => "Default"})
      assert Notifications.supports_osc9?(%{"KITTY_WINDOW_ID" => "1"})
      assert Notifications.supports_osc9?(%{"TERM" => "xterm-kitty"})
    end

    test "unknown terminals fall back to BEL" do
      refute Notifications.supports_osc9?(%{"TERM" => "xterm-256color"})
      refute Notifications.supports_osc9?(%{})
    end
  end

  describe "detect/1" do
    test "returns OSC 9 for supporting terminals and BEL otherwise" do
      assert Notifications.detect(%{"TERM_PROGRAM" => "ghostty"}) == :osc9
      assert Notifications.detect(%{"TERM" => "xterm-256color"}) == :bel
    end
  end

  describe "tmux?/1" do
    test "detects tmux through TMUX or TMUX_PANE" do
      assert Notifications.tmux?(%{"TMUX" => "/tmp/tmux-1000/default,1,0"})
      assert Notifications.tmux?(%{"TMUX_PANE" => "%0"})
      refute Notifications.tmux?(%{})
    end
  end

  describe "write/1" do
    # ExUnit runs with stdout captured, so these exercise the non-terminal
    # branch of notify/1 without emitting escape sequences.
    test "returns the applied marker when stdout is not a terminal" do
      assert Notifications.write("Turn complete") == {:ok, :applied}
    end
  end
end
