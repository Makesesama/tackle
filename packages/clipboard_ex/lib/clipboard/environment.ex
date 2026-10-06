defmodule Clipboard.Environment do
  @moduledoc """
  The session facts that decide whether a copy is also forwarded through the
  terminal.

  Inside tmux or over SSH the native clipboard may belong to a different
  machine than the one the user is sitting at, so copies are also sent to the
  user's terminal.
  """

  defstruct ssh: false, tmux: false, tmux_pane: nil

  @type t :: %__MODULE__{ssh: boolean(), tmux: boolean(), tmux_pane: String.t() | nil}

  @doc "Detects the environment from the given variables (defaults to the OS environment)."
  @spec detect(%{optional(String.t()) => String.t()}) :: t()
  def detect(env \\ System.get_env()) when is_map(env) do
    %__MODULE__{
      ssh: Map.has_key?(env, "SSH_TTY") or Map.has_key?(env, "SSH_CONNECTION"),
      tmux: Map.has_key?(env, "TMUX") or Map.has_key?(env, "TMUX_PANE"),
      tmux_pane: Map.get(env, "TMUX_PANE")
    }
  end

  @doc "Whether copies should reach the terminal even when the native copy succeeds."
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{ssh: ssh, tmux: tmux}), do: ssh or tmux
end
