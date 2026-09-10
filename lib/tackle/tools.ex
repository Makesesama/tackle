defmodule Tackle.Tools do
  @moduledoc """
  Built-in developer tools supplied by the Tackle harness.

  These tools operate relative to the current working directory by default. An
  embedding host may set `:cwd` in the session context to use another working
  directory.

  The tools run with the filesystem and operating-system permissions of the
  Tackle process. They do not provide a sandbox or confirmation boundary;
  applications that execute untrusted work should isolate the whole process.
  """

  alias Tackle.Tools.{Bash, Edit, ElixirEval, Read, Write}

  @elixir_eval_env "TACKLE_DEV"

  @doc """
  Returns the built-in tools enabled for a session unless explicitly overridden.

  `Tackle.Tools.ElixirEval` is only included when the `TACKLE_DEV` environment
  variable is truthy. It grants arbitrary code execution inside the running
  Tackle BEAM, so released builds and other non-development environments keep
  it disabled.
  """
  @spec default() :: [module()]
  def default do
    [Read, Bash] ++ optional_elixir_eval() ++ [Edit, Write]
  end

  defp optional_elixir_eval do
    if dev?(), do: [ElixirEval], else: []
  end

  defp dev? do
    case System.get_env(@elixir_eval_env) do
      value when value in [nil, "", "0", "false"] -> false
      _value -> true
    end
  end
end
