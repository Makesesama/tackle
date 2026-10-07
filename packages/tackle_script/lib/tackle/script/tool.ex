defmodule Tackle.Script.Tool do
  @moduledoc """
  Opt-in tool that runs one sandboxed Lua workflow script in the calling
  agent's own scope.

  The tool is the model-facing surface of `Tackle.Script`: the agent writes a
  Lua workflow, and the script's `tackle.spawn/2` calls become ordinary
  delegated runs under the same scope limits, admission rules, and
  cancellation as the subagent tool.

  Like `Tackle.Tools.Subagent`, exposure is deliberately opt-in and
  permissioned:

    * the host must add this module to a session's tool list;
    * the running agent must carry a runtime handle with delegation granted;
    * every profile the script names must be allowlisted — by the scope's
      trusted profiles, and, when the host narrows it, by the session context.

  A host grants the tool and, optionally, narrows the profiles scripts may
  spawn through the session context:

      Tackle.Coding.scope_spec(
        root_tools: [Tackle.Script.Tool],
        overrides: [context: %{script_profiles: ["scout", "worker"]}]
      )

  `:script_profiles` is host configuration, never script input: model-visible
  data can only name a profile from that list, and the list can only narrow
  what the scope already allows. Without it, the scope's own trusted profiles
  decide, exactly as they do for `subagent`. `Tackle.Script.run/3` documents
  the underlying `:profiles` and `:owner` options.

  The tool call owns the script's lifetime: the script is cancelled when the
  tool call ends, so a cancelled turn does not leave delegated runs behind. That
  holds where the tool body runs in its own supervised process, as the harness's
  concurrent tool policy does; a host that runs tools inline in the agent loop
  should pass its own `:owner` through `Tackle.Script.run/3`. A script that
  exceeds the session's `workflow_timeout` is cancelled too. The script's
  returned values are the tool result.
  """

  use Tackle.Lib.Tool

  alias Tackle.Runtime.Handle
  alias Tackle.Script

  tool_name("run_script")

  description(
    "Run a sandboxed Lua workflow that coordinates allowlisted subagent profiles. Use it " <>
      "for multi-step delegation expressed as code instead of one tool call per step: " <>
      "sequential steps that feed each other, bounded fan-out over a list, and retries " <>
      "driven by results. Call `tackle.spawn(profile, prompt)` to start one delegated run " <>
      "and get its handle; `tackle.await(run)` to block until it settles and return a table " <>
      "with `ok`, `status`, and `text`; `tackle.parallel(items, fn, opts)` to run one " <>
      "delegated agent per item with bounded concurrency, returning one result table per " <>
      "item in input order; `tackle.cancel(run, reason)` to cancel one run; and " <>
      "`tackle.log(message)` to report progress. The values the script returns are the tool " <>
      "result. A script can only spawn profiles this session allows scripts to use, and it " <>
      "runs under this agent's limits and cancellation."
  )

  input do
    field(:script, :string,
      required: true,
      description: "Lua source of the workflow script"
    )

    field(:timeout_ms, :integer,
      description:
        "Optional absolute script deadline in milliseconds, bounded by the scope's workflow timeout"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"script" => script} = args, context) when is_binary(script) do
    with {:ok, handle} <- fetch_handle(context),
         :ok <- ensure_delegation(handle),
         {:ok, profiles} <- script_profiles(context),
         {:ok, timeout_opts} <- timeout_opts(args),
         {:ok, ref} <- start(handle, script, profiles, timeout_opts) do
      await(ref)
    end
  end

  def run(_args, _context), do: {:error, "run_script requires a Lua script"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  # Host configuration ------------------------------------------------------------

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "run_script is unavailable: this agent has no runtime handle"}
    end
  end

  defp ensure_delegation(%Handle{allow_delegation: true}), do: :ok

  defp ensure_delegation(%Handle{}),
    do: {:error, "run_script delegation is not permitted for this agent"}

  # `nil` leaves the decision to the scope's own trusted profiles; a list
  # narrows it for scripts only. The list is bounded host configuration, so a
  # malformed one is reported rather than guessed at.
  defp script_profiles(context) do
    case Map.get(context, :script_profiles) do
      nil ->
        {:ok, nil}

      names when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and &1 != "")),
          do: {:ok, Enum.uniq(names)},
          else: {:error, "script_profiles must be a list of profile names"}

      other ->
        {:error, "script_profiles must be a list of profile names, got: #{inspect(other)}"}
    end
  end

  # A script's deadline is the scope's own `workflow_timeout`. A model-supplied
  # `timeout_ms` is only a request to finish sooner; `Tackle.Script.run/3`
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

    case Script.run(handle, script, opts) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, "could not start the script: #{describe(reason)}"}
    end
  end

  # The script's own deadline settles it, so the tool waits without a second
  # timer of its own.
  defp await(ref) do
    case Script.await(ref, :infinity) do
      {:ok, values} -> {:ok, format_values(values)}
      {:error, reason} -> {:error, script_error(reason)}
    end
  end

  defp format_values([]), do: "(the script returned no values)"

  defp format_values(values) when is_list(values),
    do: Enum.map_join(values, "\n", &format_value/1)

  defp format_values(other), do: format_value(other)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_value(nil), do: "nil"
  defp format_value(value), do: inspect(value)

  defp script_error(%{message: message} = reason) do
    case Map.get(reason, :line) do
      line when is_integer(line) -> "the script failed at line #{line}: #{message}"
      _other -> "the script failed: #{message}"
    end
  end

  defp script_error({:script_compile_error, message}),
    do: "the script does not compile: #{message}"

  defp script_error({:cancelled, :script_timeout}), do: "the script exceeded its deadline"
  defp script_error({:cancelled, reason}), do: "the script was cancelled (#{describe(reason)})"
  defp script_error({:script_crashed, message}), do: "the script crashed: #{message}"

  defp script_error({:script_worker_terminated, reason}),
    do: "the script terminated unexpectedly: #{describe(reason)}"

  defp script_error({:script_exit, reason}), do: "the script exited: #{describe(reason)}"

  defp script_error({:script_terminated, reason}),
    do: "the script was stopped: #{describe(reason)}"

  defp script_error(:script_timeout), do: "the script exceeded its deadline"
  defp script_error(:not_found), do: "the script is no longer running"
  defp script_error(reason), do: "the script failed: #{describe(reason)}"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
