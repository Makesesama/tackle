defmodule Tackle.Elixir.Project do
  @moduledoc """
  Finds the Mix project a source file belongs to.
  """

  alias Tackle.Executor

  @source_extensions [".ex", ".heex", ".eex", ".leex"]
  @ignored_segments ["deps", "_build"]

  @doc """
  Whether `path` may be an input of `mix compile`, judged by its name alone:
  Elixir sources and templates and `.exs` scripts. A cheap check before
  `root/2` and `compile_input?/1`.
  """
  @spec elixir_file?(Path.t()) :: boolean()
  def elixir_file?(path) when is_binary(path),
    do: Path.extname(path) in [".exs" | @source_extensions]

  @doc """
  Whether a change to `relative_path`, relative to its project's root, can
  change what `mix compile` reports: Elixir sources and templates, `mix.exs`,
  and scripts under `config/`. Files under `deps/` and `_build/` are not the
  project's own and are left out.
  """
  @spec compile_input?(Path.t()) :: boolean()
  def compile_input?(relative_path) when is_binary(relative_path) do
    segments = Path.split(relative_path)

    cond do
      Enum.any?(segments, &(&1 in @ignored_segments)) -> false
      Path.extname(relative_path) in @source_extensions -> true
      relative_path == "mix.exs" -> true
      Path.extname(relative_path) == ".exs" -> hd(segments) == "config"
      true -> false
    end
  end

  @doc """
  Returns the directory of the nearest `mix.exs` above the absolute `path`,
  checked through `executor`. In an umbrella that is the application's
  directory. A project directly inside a `deps/` directory is another
  project's dependency and is not returned.
  """
  @spec root(Executor.t(), Path.t()) :: {:ok, Path.t()} | :error
  def root(executor, path) when is_binary(path) do
    with {:ok, dir} <- path |> Path.dirname() |> find_root(executor) do
      if dir |> Path.dirname() |> Path.basename() == "deps", do: :error, else: {:ok, dir}
    end
  end

  defp find_root(dir, executor) do
    case Executor.stat(executor, Path.join(dir, "mix.exs")) do
      {:ok, %{type: :regular}} ->
        {:ok, dir}

      _missing ->
        case Path.dirname(dir) do
          ^dir -> :error
          parent -> find_root(parent, executor)
        end
    end
  end
end
