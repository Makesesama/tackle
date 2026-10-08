defmodule Tackle.Workflow.Tool do
  @moduledoc """
  Opt-in tool that runs one sandboxed Lua workflow in the calling
  agent's own scope.

  The tool is the model-facing surface of `Tackle.Workflow`: the agent writes a
  Lua workflow, and its `tackle.spawn/2` calls become ordinary
  delegated runs under the same scope limits, admission rules, and
  cancellation as the subagent tool.

  Like `Tackle.Tools.Subagent`, exposure is deliberately opt-in and
  permissioned:

    * the host must add this module to a session's tool list;
    * the running agent must carry a runtime handle with delegation granted;
    * every profile the workflow names must be allowlisted — by the scope's
      trusted profiles, and, when the host narrows it, by the session context.

  A host grants the tool and, optionally, narrows the profiles workflows may
  spawn through the session context:

      Tackle.Coding.scope_spec(
        root_tools: [Tackle.Workflow.Tool],
        overrides: [context: %{workflow_profiles: ["scout", "worker"]}]
      )

  `:workflow_profiles` is host configuration, never workflow input: model-visible
  data can only name a profile from that list, and the list can only narrow
  what the scope already allows. Without it, the scope's own trusted profiles
  decide, exactly as they do for `subagent`. `Tackle.Workflow.run/3` documents
  the underlying `:profiles` and `:owner` options.

  The tool call owns the workflow's lifetime: the workflow is cancelled when the
  tool call ends, so a cancelled turn does not leave delegated runs behind. That
  holds where the tool body runs in its own supervised process, as the harness's
  concurrent tool policy does; a host that runs tools inline in the agent loop
  should pass its own `:owner` through `Tackle.Workflow.run/3`. A workflow that
  exceeds the session's `workflow_timeout` is cancelled too. The workflow's
  returned values are the tool result.
  """

  use Tackle.Lib.Tool

  alias Tackle.Runtime.Handle
  alias Tackle.Workflow

  tool_name("run_workflow")

  description(
    "Run a sandboxed Lua workflow that coordinates allowlisted subagent profiles. Use it " <>
      "for multi-step delegation expressed as code instead of one tool call per step: " <>
      "sequential steps that feed each other, bounded fan-out over a list, and retries " <>
      "driven by results. Call `tackle.spawn(profile, prompt)` to start one delegated run " <>
      "and get its handle; `tackle.await(run)` to block until it settles and return a table " <>
      "with `ok`, `status`, and `text`; `tackle.parallel(items, fn, opts)` to run one " <>
      "delegated agent per item with bounded concurrency, returning one result table per " <>
      "item in input order; `tackle.cancel(run, reason)` to cancel one run; and " <>
      "`tackle.log(message)` to report progress. The values the workflow returns are the tool " <>
      "result. A workflow can only spawn profiles this session allows it to use, and it " <>
      "runs under this agent's limits and cancellation."
  )

  input do
    field(:script, :string,
      required: true,
      description: "Lua source of the workflow"
    )

    field(:timeout_ms, :integer,
      description:
        "Optional absolute workflow deadline in milliseconds, bounded by the scope's workflow timeout"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"script" => script} = args, context) when is_binary(script) do
    with {:ok, handle} <- fetch_handle(context),
         :ok <- ensure_delegation(handle),
         {:ok, profiles} <- workflow_profiles(context),
         {:ok, timeout_opts} <- timeout_opts(args),
         {:ok, ref} <- start(handle, script, profiles, timeout_opts) do
      await(ref)
    end
  end

  def run(_args, _context), do: {:error, "run_workflow requires a Lua script"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  # Host configuration ------------------------------------------------------------

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "run_workflow is unavailable: this agent has no runtime handle"}
    end
  end

  defp ensure_delegation(%Handle{allow_delegation: true}), do: :ok

  defp ensure_delegation(%Handle{}),
    do: {:error, "run_workflow delegation is not permitted for this agent"}

  # `nil` leaves the decision to the scope's own trusted profiles; a list
  # narrows it for workflows only. The list is bounded host configuration, so a
  # malformed one is reported rather than guessed at.
  defp workflow_profiles(context) do
    case Map.get(context, :workflow_profiles) do
      nil ->
        {:ok, nil}

      names when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and &1 != "")),
          do: {:ok, Enum.uniq(names)},
          else: {:error, "workflow_profiles must be a list of profile names"}

      other ->
        {:error, "workflow_profiles must be a list of profile names, got: #{inspect(other)}"}
    end
  end

  # A workflow's deadline is the scope's own `workflow_timeout`. A model-supplied
  # `timeout_ms` is only a request to finish sooner; `Tackle.Workflow.run/3`
  # clamps it against the inherited limit, so the option is omitted when the
  # agent asked for no particular deadline.
  defp timeout_opts(args) do
    case Map.get(args, "timeout_ms") do
      nil -> {:ok, []}
      ms when is_integer(ms) and ms > 0 -> {:ok, [timeout: ms]}
      _other -> {:error, "timeout_ms must be a positive integer"}
    end
  end

  # Run ---------------------------------------------------------------------------

  defp start(handle, script, profiles, timeout_opts) do
    opts = [profiles: profiles, owner: self()] ++ timeout_opts

    case Workflow.run(handle, script, opts) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, "could not start the workflow: #{describe(reason)}"}
    end
  end

  # The workflow's own deadline settles it, so the tool waits without a second
  # timer of its own.
  defp await(ref) do
    case Workflow.await(ref, :infinity) do
      {:ok, values} -> {:ok, format_values(values)}
      {:error, reason} -> {:error, workflow_error(reason)}
    end
  end

  defp format_values([]), do: "(the workflow returned no values)"

  defp format_values(values) when is_list(values),
    do: Enum.map_join(values, "\n", &format_value/1)

  defp format_values(other), do: format_value(other)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_value(nil), do: "nil"
  defp format_value(value), do: inspect(value)

  defp workflow_error(%{message: message} = reason) do
    case Map.get(reason, :line) do
      line when is_integer(line) -> "the workflow failed at line #{line}: #{message}"
      _other -> "the workflow failed: #{message}"
    end
  end

  defp workflow_error({:workflow_compile_error, message}),
    do: "the workflow does not compile: #{message}"

  defp workflow_error({:cancelled, :workflow_timeout}), do: "the workflow exceeded its deadline"

  defp workflow_error({:cancelled, reason}),
    do: "the workflow was cancelled (#{describe(reason)})"

  defp workflow_error({:workflow_crashed, message}), do: "the workflow crashed: #{message}"

  defp workflow_error({:workflow_worker_terminated, reason}),
    do: "the workflow terminated unexpectedly: #{describe(reason)}"

  defp workflow_error({:workflow_exit, reason}), do: "the workflow exited: #{describe(reason)}"

  defp workflow_error({:workflow_terminated, reason}),
    do: "the workflow was stopped: #{describe(reason)}"

  defp workflow_error(:workflow_timeout), do: "the workflow exceeded its deadline"
  defp workflow_error(:not_found), do: "the workflow is no longer running"
  defp workflow_error(reason), do: "the workflow failed: #{describe(reason)}"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
