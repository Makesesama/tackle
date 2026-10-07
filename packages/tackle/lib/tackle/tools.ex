defmodule Tackle.Tools do
  @moduledoc """
  Built-in developer tools supplied by the Tackle harness.

  These tools operate relative to the current working directory by default. An
  embedding host may set `:cwd` in the session context to use another working
  directory.

  The tools send filesystem and process primitives to the executor in
  `context.executor` (see `Tackle.Executor`). The default
  `Tackle.Executor.Local` runs them with the Tackle process's own permissions,
  without a sandbox or confirmation boundary; `Tackle.Executor.Jailed` runs them
  inside a jail.
  """

  alias Tackle.Tools.{Bash, Edit, Read, Write}

  @doc "Returns the built-in tools enabled for a session unless explicitly overridden."
  @spec default() :: [module()]
  def default, do: [Read, Bash, Edit, Write]

  @doc "Resolves names only from a trusted set of already-selected tool modules."
  @spec resolve_names([String.t()], [module()]) ::
          {:ok, [module()]} | {:error, {:unknown_tool_names, [String.t()]}}
  def resolve_names(names, trusted_tools) when is_list(names) and is_list(trusted_tools) do
    tools_by_name = Map.new(trusted_tools, &{&1.name(), &1})
    unknown = names |> Enum.reject(&Map.has_key?(tools_by_name, &1)) |> Enum.uniq() |> Enum.sort()

    case unknown do
      [] -> {:ok, Enum.map(names, &Map.fetch!(tools_by_name, &1))}
      unknown -> {:error, {:unknown_tool_names, unknown}}
    end
  end
end
