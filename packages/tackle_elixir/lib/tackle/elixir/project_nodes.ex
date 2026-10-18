defmodule Tackle.Elixir.ProjectNodes do
  @moduledoc """
  One `Tackle.Elixir.ProjectNode` per executor, started on first use.

  Sessions that share an executor (the root agent and its subagents, or two
  sessions in the same jail) share its broker, which runs one project node per
  Mix project. A client stops after its idle timeout, or when its broker
  fails; the next request starts a new one.
  """

  alias Tackle.Elixir.ProjectNode
  alias Tackle.Executor

  @registry Tackle.Elixir.ProjectNodes.Registry
  @supervisor Tackle.Elixir.ProjectNodes.Supervisor

  @doc false
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc """
  Returns the client for `executor`, starting it and its broker if needed.
  `opts` are passed to `Tackle.Elixir.ProjectNode.start_link/1` on start.
  """
  @spec fetch(Executor.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def fetch(executor, opts \\ []) do
    case Registry.lookup(@registry, executor) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        spec = %{
          id: ProjectNode,
          start:
            {ProjectNode, :start_link,
             [
               Keyword.merge(opts,
                 executor: executor,
                 name: {:via, Registry, {@registry, executor}}
               )
             ]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Compiles the Mix project at `root` through `executor`'s project node; see
  `Tackle.Elixir.ProjectNode.compile/3`.
  """
  @spec compile(Executor.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, ProjectNode.error() | term()}
  def compile(executor, root, opts \\ []) do
    with {:ok, pid} <- fetch(executor, Keyword.get(opts, :start, [])) do
      case ProjectNode.compile(pid, root, opts) do
        # The client stopped (idle timeout) between lookup and request; the
        # next fetch starts a new one.
        {:error, :node_down} -> retry(executor, root, opts, pid)
        result -> result
      end
    end
  end

  defp retry(executor, root, opts, stopped) do
    case fetch(executor, Keyword.get(opts, :start, [])) do
      {:ok, ^stopped} -> {:error, :node_down}
      {:ok, pid} -> ProjectNode.compile(pid, root, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the client for `executor` and its broker, if running."
  @spec stop(Executor.t()) :: :ok
  def stop(executor) do
    case Registry.lookup(@registry, executor) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end

    :ok
  end
end
