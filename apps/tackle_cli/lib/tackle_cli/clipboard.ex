defmodule Tackle.CLI.Clipboard do
  @moduledoc """
  Copies text to the system clipboard for the shell.

  Backed by `:clipboard_ex`: the native clipboard is tried first, and the
  user's terminal is reached through tmux or OSC 52 when the native copy fails
  or the session is remote (SSH or tmux), where the native clipboard may
  belong to another machine than the one the user is sitting at.

  The result says how certain the copy is, so the status row can report it
  honestly:

    * `{:ok, :confirmed}` - the native clipboard accepted the text.
    * `{:ok, :requested}` - only the terminal was asked. Terminals never
      acknowledge OSC 52, so the copy may or may not have happened.
    * `{:error, reason}` - every transport failed.

  The native call is bounded by `@native_timeout`: a hung display server
  delays a copy by at most that long instead of freezing the shell forever.
  """

  @native_timeout 2_000

  @type copy_result :: {:ok, :confirmed | :requested} | {:error, term()}

  @doc "Copies `text` to the system clipboard, reaching the terminal when needed."
  @spec copy(binary()) :: copy_result()
  def copy(text) when is_binary(text), do: Clipboard.copy(text, timeout: @native_timeout)
end
