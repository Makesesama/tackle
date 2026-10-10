defmodule Tackle.Workflow do
  @moduledoc """
  Lua-scripted agent workflows on top of `Tackle.Runtime`.

  A host or an agent describes a flow — scout, then plan, then implement,
  then review — and the Lua script encodes it as ordinary code. The workflow runs
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

      {:ok, ref} = Tackle.Workflow.run(handle, script)
      Tackle.Workflow.await(ref)

  Because `tackle.spawn/2` returns immediately and `tackle.await/1` blocks only
  the workflow, fan-out is explicit Lua with overlapping runs:

      local a = tackle.spawn(\"researcher\", \"Topic A\")
      local b = tackle.spawn(\"researcher\", \"Topic B\")
      local first = tackle.await(a)
      local second = tackle.await(b)

  `tackle.parallel/2,3` packages that into bounded fan-out, so a workflow does
  not have to hand-build the coordination:

      local answers = tackle.parallel(questions, function(question, index)
        return "researcher", index .. ". " .. question
      end, {limit = 3})

  At most `limit` runs are in flight, and a freed slot is reused as soon as a
  run settles. The limit is clamped to the scope's own concurrency ceiling,
  and every item yields one result table in input order. Item failures are
  returned, never raised, so the workflow decides whether to retry them.

  Scripts are evaluated with the sandboxed, pure-Elixir `Lua` VM: no file
  system, no network, no `os.execute`, and a deterministic instruction budget.
  See `Tackle.Workflow.API` for the complete Lua surface.

  Two options narrow a workflow beyond its parent's grants. `:profiles` is an
  explicit allowlist of profile names the workflow may spawn; `:owner` is the
  process whose lifetime the workflow shares, so a cancelled tool call does not
  leave delegated runs behind. `Tackle.Workflow.Tool` is the model-facing tool a
  host grants to a session for both.

  The workflow's settled result is `{:ok, values}` — the list of values the
  Lua script returned — or `{:error, reason}` for workflow errors, cancellation,
  and timeouts. Every run the workflow spawned is cancelled when the workflow
  ends, however it ends.
  """

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Ref
  alias Tackle.Workflow.Ref, as: WorkflowRef
  alias Tackle.Workflow.Server

  @doc """
  Starts one scripted workflow under the scope work supervisor.

  The workflow's delegated runs are admitted as children of `parent`, so scope
  limits, spawn depth, and cancellation apply unchanged. Returns a stable
  `Tackle.Workflow.Ref` for `await/2`.

  ## Options

    * `:timeout` — absolute workflow deadline in milliseconds. Defaults to the
      parent's inherited `workflow_timeout` limit, and is clamped to it: a
      caller may shorten a workflow's deadline, never extend the one its parent
      already has.
    * `:max_instructions` — Lua VM instruction budget guarding against spin
      loops that never await. Defaults to `1_000_000`; `:infinity` disables it.
    * `:token_budget` — positive number of model tokens the workflow's runs may
      spend together. Once their reported usage reaches it, `tackle.spawn`
      raises and `tackle.parallel` reports `"budget_exhausted"` for new items;
      runs already in flight finish. Defaults to `nil`, no budget.
      `Tackle.Workflow.Meter` documents what is counted.
    * `:profiles` — explicit allowlist of profile names the workflow may name in
      `tackle.spawn/2` and `tackle.parallel/3`. Defaults to `nil`, which
      delegates the decision to the scope's own trusted profile allowlist. An
      empty list allows a workflow to run but refuse every spawn, so a host can
      grant scripted workflows without granting delegation.
    * `:owner` — optional PID whose lifetime the workflow shares. When it
      terminates, the workflow and every run it started are cancelled. A
      model-facing tool passes the process serving the tool call, so a
      cancelled turn does not leave delegated runs behind.
    * `:log` — one-arity callback receiving `tackle.log/1` messages. Defaults
      to `Logger`. An `:on_event` observer receives them as well.
    * `:on_event` — one-arity callback receiving the workflow's progress as it
      runs: the delegated runs it starts, their child agents' events, the
      outcomes it observes, its `tackle.parallel` batches, and its log
      messages. `Tackle.Workflow.Progress` documents each event. Progress is
      presentation only; a failing callback never affects the workflow.

  `:profiles`, `:token_budget`, and `:owner` are host options: they describe
  what the caller already decided, never what a workflow asked for.
  """
  @spec run(Handle.t() | AgentRef.t(), String.t(), keyword()) ::
          {:ok, WorkflowRef.t()} | {:error, term()}
  def run(parent, script, opts \\ []) when is_binary(script) do
    with {:ok, scope_ref, parent_ref} <- resolve_requester(parent),
         {:ok, handle} <- authorized_handle(scope_ref, parent_ref),
         {:ok, profiles} <- profiles(Keyword.get(opts, :profiles)),
         {:ok, owner} <- owner(Keyword.get(opts, :owner)),
         {:ok, on_event} <- on_event(Keyword.get(opts, :on_event)),
         {:ok, timeout} <- timeout(Keyword.get(opts, :timeout), handle.limits),
         {:ok, token_budget} <- token_budget(Keyword.get(opts, :token_budget)),
         {:ok, workflow_ref} <- WorkflowRef.new(scope_ref.scope_id, ID.generate()) do
      arg = %{
        workflow_ref: workflow_ref,
        handle: handle,
        script: script,
        profiles: profiles,
        owner: owner,
        timeout: timeout,
        max_instructions: Keyword.get(opts, :max_instructions),
        token_budget: token_budget,
        log: Keyword.get(opts, :log),
        on_event: on_event
      }

      case Runtime.start_work(parent, Server.child_spec(arg)) do
        {:ok, _pid} -> {:ok, workflow_ref}
        {:error, reason} -> {:error, {:workflow_start_failed, reason}}
      end
    end
  end

  @doc "Waits for a workflow's terminal result."
  @spec await(WorkflowRef.t(), timeout()) :: term()
  def await(%WorkflowRef{} = workflow_ref, timeout \\ :infinity) do
    case Registry.lookup(
           Tackle.Workflow.Registry,
           {workflow_ref.scope_id, workflow_ref.workflow_id}
         ) do
      [{server, _owner}] ->
        try do
          Server.await(server, timeout)
        catch
          :exit, reason -> {:error, {:workflow_terminated, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Requests cooperative cancellation of the workflow and its runs."
  @spec cancel(WorkflowRef.t(), term()) :: :ok | {:error, term()}
  def cancel(%WorkflowRef{} = workflow_ref, reason \\ :cancelled) do
    case Registry.lookup(
           Tackle.Workflow.Registry,
           {workflow_ref.scope_id, workflow_ref.workflow_id}
         ) do
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

  defp profiles(nil), do: {:ok, nil}

  defp profiles(names) when is_list(names) do
    if Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(names)},
      else: {:error, {:invalid_workflow_option, :profiles, names}}
  end

  defp profiles(value), do: {:error, {:invalid_workflow_option, :profiles, value}}

  defp owner(nil), do: {:ok, nil}
  defp owner(pid) when is_pid(pid), do: {:ok, pid}
  defp owner(value), do: {:error, {:invalid_workflow_option, :owner, value}}

  defp on_event(nil), do: {:ok, nil}
  defp on_event(callback) when is_function(callback, 1), do: {:ok, callback}
  defp on_event(value), do: {:error, {:invalid_workflow_option, :on_event, value}}

  defp token_budget(nil), do: {:ok, nil}
  defp token_budget(budget) when is_integer(budget) and budget > 0, do: {:ok, budget}
  defp token_budget(value), do: {:error, {:invalid_workflow_option, :token_budget, value}}

  defp timeout(nil, %Limits{workflow_timeout: inherited}), do: {:ok, inherited}
  defp timeout(nil, nil), do: {:ok, :infinity}

  defp timeout(requested, limits)
       when requested == :infinity or (is_integer(requested) and requested > 0) do
    case limits do
      %Limits{workflow_timeout: inherited} -> {:ok, min(requested, inherited)}
      nil -> {:ok, requested}
    end
  end

  defp timeout(value, _limits), do: {:error, {:invalid_workflow_option, :timeout, value}}

  # A workflow may only delegate as far as its parent may. The parent's snapshot
  # carries the effective grants the runner builds its handle from.
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
