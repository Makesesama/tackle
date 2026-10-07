defmodule Tackle.Script do
  @moduledoc """
  Lua-scripted agent workflows on top of `Tackle.Runtime`.

  A host or an agent describes a flow — scout, then plan, then implement,
  then review — and the script encodes it as ordinary Lua code. The script runs
  in its own process under the scope work supervisor as a cancellable child,
  with the same allowlisted profiles, scope limits, and admission rules as
  host-defined workflows:

      script = \"\"\"
      local findings = tackle.await(tackle.spawn(\"scout\", \"Map the code paths.\"))
      local plan = tackle.await(tackle.spawn(\"planner\", \"Plan: \" .. findings.text))
      local impl = tackle.await(tackle.spawn(\"worker\", \"Implement: \" .. plan.text))

      local review = tackle.await(tackle.spawn(\"reviewer\", \"Review the change.\"))
      while not review.ok do
        impl = tackle.await(tackle.spawn(\"worker\", \"Fix: \" .. review.text))
        review = tackle.await(tackle.spawn(\"reviewer\", \"Re-review the change.\"))
      end

      return review.text
      \"\"\"

      {:ok, ref} = Tackle.Script.run(handle, script)
      Tackle.Script.await(ref)

  Because `tackle.spawn/2` returns immediately and `tackle.await/1` blocks only
  the script, fan-out is sequential Lua with overlapping runs:

      local a = tackle.spawn(\"researcher\", \"Topic A\")
      local b = tackle.spawn(\"researcher\", \"Topic B\")
      local first = tackle.await(a)
      local second = tackle.await(b)

  Scripts are evaluated with the sandboxed, pure-Elixir `Lua` VM: no file
  system, no network, no `os.execute`, and a deterministic instruction budget.
  See `Tackle.Script.API` for the complete script surface.

  The script's settled result is `{:ok, values}` — the list of values the
  script returned — or `{:error, reason}` for script errors, cancellation,
  and timeouts. Every run the script spawned is cancelled when the script
  ends, however it ends.
  """

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Ref
  alias Tackle.Script.Ref, as: ScriptRef
  alias Tackle.Script.Server

  @doc """
  Starts one scripted workflow under the scope work supervisor.

  The script's delegated runs are admitted as children of `parent`, so scope
  limits, spawn depth, and cancellation apply unchanged. Returns a stable
  `Tackle.Script.Ref` for `await/2`.

  ## Options

    * `:timeout` — absolute script deadline in milliseconds. Defaults to the
      parent's inherited `workflow_timeout` limit.
    * `:max_instructions` — Lua VM instruction budget guarding against spin
      loops that never await. Defaults to `1_000_000`; `:infinity` disables it.
    * `:log` — one-arity callback receiving `tackle.log/1` messages. Defaults
      to `Logger`.
  """
  @spec run(Handle.t() | AgentRef.t(), String.t(), keyword()) ::
          {:ok, ScriptRef.t()} | {:error, term()}
  def run(parent, script, opts \\ []) when is_binary(script) do
    with {:ok, scope_ref, parent_ref} <- resolve_requester(parent),
         {:ok, handle} <- authorized_handle(scope_ref, parent_ref),
         {:ok, script_ref} <- ScriptRef.new(scope_ref.scope_id, ID.generate()) do
      arg = %{
        script_ref: script_ref,
        handle: handle,
        script: script,
        timeout: Keyword.get(opts, :timeout, handle.limits && handle.limits.workflow_timeout),
        max_instructions: Keyword.get(opts, :max_instructions),
        log: Keyword.get(opts, :log)
      }

      case Runtime.start_work(parent, Server.child_spec(arg)) do
        {:ok, _pid} -> {:ok, script_ref}
        {:error, reason} -> {:error, {:script_start_failed, reason}}
      end
    end
  end

  @doc "Waits for a script's terminal result."
  @spec await(ScriptRef.t(), timeout()) :: term()
  def await(%ScriptRef{} = script_ref, timeout \\ :infinity) do
    case Registry.lookup(Tackle.Script.Registry, {script_ref.scope_id, script_ref.script_id}) do
      [{server, _owner}] ->
        try do
          Server.await(server, timeout)
        catch
          :exit, reason -> {:error, {:script_terminated, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Requests cooperative cancellation of the script and its runs."
  @spec cancel(ScriptRef.t(), term()) :: :ok | {:error, term()}
  def cancel(%ScriptRef{} = script_ref, reason \\ :cancelled) do
    case Registry.lookup(Tackle.Script.Registry, {script_ref.scope_id, script_ref.script_id}) do
      [{server, _owner}] ->
        Server.cancel(server, reason)

      [] ->
        {:error, :not_found}
    end
  end

  defp resolve_requester(%Handle{scope_ref: scope_ref, agent_ref: agent_ref}),
    do: {:ok, scope_ref, agent_ref}

  defp resolve_requester(%AgentRef{} = agent_ref),
    do: {:ok, Ref.scope_ref(agent_ref), agent_ref}

  defp resolve_requester(other), do: {:error, {:invalid_requester, other}}

  # A script may only delegate as far as its parent may. The parent's snapshot
  # carries the effective grants, exactly like `Runtime.start_workflow/4`.
  defp authorized_handle(scope_ref, parent_ref) do
    case Runtime.agent_snapshot(parent_ref) do
      {:ok, snapshot} ->
        handle =
          Handle.new(scope_ref, parent_ref,
            allow_delegation: snapshot.allow_delegation,
            limits: snapshot.limits
          )

        {:ok, handle}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
