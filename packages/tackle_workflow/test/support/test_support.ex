defmodule Tackle.Workflow.TestSupport do
  @moduledoc false

  import ExUnit.Assertions

  # Test helpers for scripted-workflow tests: a scope with the deterministic
  # `Tackle.Workflow.TestBackend` and an authorized runtime handle.

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec

  @doc "Builds a trusted agent spec for the fake backend."
  def agent_spec(name, opts \\ []) do
    AgentSpec.new!(
      name: name,
      config: config(opts),
      allow_delegation: Keyword.get(opts, :allow_delegation, false),
      timeout: Keyword.get(opts, :timeout, 5_000)
    )
  end

  defp config(opts) do
    base = %{
      mode: Keyword.get(opts, :mode, :echo_prompt),
      test_pid: self(),
      events: Keyword.get(opts, :events, [])
    }

    case Keyword.fetch(opts, :content) do
      {:ok, content} -> Map.put(base, :content, content)
      :error -> base
    end
  end

  @doc "Starts a scope with delegation allowed and registers cleanup."
  def start_scope(opts \\ []) do
    root_opts =
      opts
      |> Keyword.get(:root, [])
      |> Keyword.put_new(:allow_delegation, true)

    spec =
      ScopeSpec.new!(
        backend: Tackle.Workflow.TestBackend,
        root_spec: agent_spec("root", root_opts),
        limits: Keyword.get(opts, :limits, Limits.default()),
        profiles: Keyword.get(opts, :profiles, %{})
      )

    {:ok, scope} = Runtime.start_scope(spec)
    ExUnit.Callbacks.on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  def stop_scope(scope_ref) do
    Runtime.stop_scope(scope_ref)
  catch
    :exit, _reason -> :ok
  end

  @doc "Builds an authorized runtime handle for a started scope."
  def handle(scope, opts \\ []) do
    Handle.new(scope.scope_ref, scope.root_agent_ref,
      allow_delegation: Keyword.get(opts, :allow_delegation, true),
      limits: Keyword.get(opts, :limits)
    )
  end

  @doc "Waits until `fun` returns a truthy value."
  def assert_eventually(fun, attempts \\ 200)

  def assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  def assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
