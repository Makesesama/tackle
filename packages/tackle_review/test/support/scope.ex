defmodule Tackle.Review.Test.Scope do
  @moduledoc false
  # Runtime scopes for review tests, on `Tackle.Runtime.LoopAgent`.

  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, Limits, LoopAgent, ScopeSpec}

  @doc """
  Starts a scope stopped when the test exits. `:root_config` is a backend
  configuration for the root agent (it never runs a turn); `:root` options
  go to its `AgentSpec`; `:profiles` and `:limits` to the scope.
  """
  def start(opts) do
    root =
      AgentSpec.new!(
        [name: "root", config: Keyword.fetch!(opts, :root_config)] ++
          Keyword.get(opts, :root, allow_delegation: true)
      )

    spec =
      ScopeSpec.new!(
        backend: LoopAgent,
        root_spec: root,
        limits: Keyword.get(opts, :limits, Limits.default()),
        profiles: Keyword.get(opts, :profiles, %{})
      )

    {:ok, scope} = Runtime.start_scope(spec)
    ExUnit.Callbacks.on_exit(fn -> stop(scope.scope_ref) end)
    scope
  end

  @doc "Stops a scope if it is still alive."
  def stop(scope_ref) do
    Runtime.stop_scope(scope_ref)
  catch
    :exit, _reason -> :ok
  end

  @doc "Waits until `fun` returns a truthy value; `:ok` or `:timeout`."
  def eventually(fun, attempts \\ 200)

  def eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  def eventually(_fun, 0), do: :timeout
end
