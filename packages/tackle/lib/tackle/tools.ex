defmodule Tackle.Tools do
  @moduledoc """
  The tool sets the coding harness composes sessions and agent profiles from.

  `default/0` is a session's tools unless the host configures others: the
  coding tools of `packages/tackle_tools` (`Tackle.Tools.Read`, `Bash`,
  `Edit`, and `Write`, which run through the session's executor; see
  `Tackle.Executor`). `review/0` is the code review output tools agent
  profiles may name, and `resolve_names/2` resolves the tool names of an
  agent profile against modules the host already trusts, so a definition
  file can never load a module of its own.
  """

  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Tools.{Bash, Edit, Read, Write}

  @doc "Returns the built-in tools enabled for a session unless explicitly overridden."
  @spec default() :: [module()]
  def default, do: [Read, Bash, Edit, Write]

  @doc """
  Returns the structured output tools of the code review profiles
  (`review-detector`, `review-verifier`).

  Agent profiles may select them by name; they are never part of the default
  or root tool set, and they only work in runs started by `Tackle.Review`.
  """
  @spec review() :: [module()]
  def review, do: [ReportFindings, ReportVerdict]

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
