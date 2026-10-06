defmodule Clipboard.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Clipboard.Environment

  test "a plain local session is not remote" do
    environment = Environment.detect(%{"HOME" => "/home/user"})
    assert environment == %Environment{ssh: false, tmux: false, tmux_pane: nil}
    refute Environment.remote?(environment)
  end

  test "detects SSH from either variable" do
    assert Environment.detect(%{"SSH_TTY" => "/dev/pts/0"}).ssh
    assert Environment.detect(%{"SSH_CONNECTION" => "10.0.0.1 1 10.0.0.2 22"}).ssh
    assert Environment.remote?(Environment.detect(%{"SSH_TTY" => "/dev/pts/0"}))
  end

  test "detects tmux and keeps the pane" do
    environment =
      Environment.detect(%{"TMUX" => "/tmp/tmux-1000/default,1,0", "TMUX_PANE" => "%3"})

    assert environment.tmux
    assert environment.tmux_pane == "%3"
    assert Environment.remote?(environment)
  end
end
