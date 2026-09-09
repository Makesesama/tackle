defmodule Tackle.CLI.Clipboard do
  @moduledoc """
  Copies text through the terminal using the OSC 52 clipboard protocol.

  Terminals that do not support OSC 52 safely ignore the sequence.
  """

  @doc "Returns the OSC 52 escape sequence for `content`."
  @spec osc52(binary()) :: binary()
  def osc52(content) when is_binary(content) do
    "\e]52;c;" <> Base.encode64(content) <> "\a"
  end

  @doc "Writes an OSC 52 copy request to the local terminal."
  @spec copy_local(binary()) :: :ok | {:error, term()}
  def copy_local(content) when is_binary(content) do
    IO.binwrite(:stdio, osc52(content))
  end
end
