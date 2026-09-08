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

  @doc "Returns the built-in tools enabled for a session unless explicitly overridden."
  @spec default() :: [module()]
  def default, do: [Read, Bash, ElixirEval, Edit, Write]
end
