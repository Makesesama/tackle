defmodule Tackle.Script.API do
  @moduledoc """
  Lua API surface exposed to workflow scripts.

  Scripts call these functions through the global `tackle` table:

      local run = tackle.spawn("scout", "Map the code paths for the change.")
      local outcome = tackle.await(run)
      if outcome.ok then
        return outcome.text
      end

  * `tackle.spawn(profile, prompt)` starts one delegated run through the same
    allowlisted profiles, scope limits, and admission rules as the subagent
    tool and host-defined workflows. It returns an opaque run handle
    immediately, so several spawns overlap.
  * `tackle.await(run)` blocks the script until the run settles and returns an
    outcome table with `ok`, `status`, and `text` fields. Expected failures
    (agent errors, cancellations, timeouts) are returned, never raised, so
    scripts decide their own failure policy.
  * `tackle.cancel(run, reason)` requests cooperative cancellation of one run.
  * `tackle.log(message)` reports progress to the host's log callback.

  Invalid arguments and rejected spawns raise catchable Lua errors carrying
  the script's source line, so scripts can implement policy with `pcall`.
  """

  use Lua.API, scope: "tackle"

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  @doc "Starts one delegated agent run and returns its opaque run handle."
  deflua spawn(profile, prompt) when is_binary(profile) and is_binary(prompt), state do
    %{handle: %Handle{} = handle} = context!(state)

    case Runtime.request_agent(handle, profile, prompt) do
      {:ok, %RunRef{} = run_ref} ->
        {encoded, state} = Lua.encode!(state, {:userdata, run_ref})
        {encoded, state}

      {:error, reason} ->
        runtime_exception!("spawn failed: #{inspect(reason)}")
    end
  end

  deflua spawn(_profile, _prompt), _state do
    runtime_exception!("tackle.spawn(profile, prompt) requires two strings")
  end

  @doc "Waits for one run and returns its outcome table."
  deflua await(run), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.await(run_ref, :infinity) do
      %Outcome{} = outcome ->
        {encoded, state} = Lua.encode!(state, outcome_table(outcome))
        {encoded, state}

      {:error, reason} ->
        runtime_exception!("await failed: #{inspect(reason)}")
    end
  end

  @doc "Requests cooperative cancellation of one run."
  deflua cancel(run), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.cancel(run_ref, :cancelled) do
      :ok -> {true, state}
      {:error, reason} -> runtime_exception!("cancel failed: #{inspect(reason)}")
    end
  end

  deflua cancel(run, reason) when is_binary(reason), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.cancel(run_ref, reason) do
      :ok -> {true, state}
      {:error, failure} -> runtime_exception!("cancel failed: #{inspect(failure)}")
    end
  end

  @doc "Reports one progress message to the host's log callback."
  deflua log(message) when is_binary(message), state do
    %{server: server} = context!(state)
    send(server, {:script_log, message})
    {true, state}
  end

  deflua log(_message), _state do
    runtime_exception!("tackle.log(message) requires a string")
  end

  # Outcome projection ------------------------------------------------------------

  defp outcome_table(%Outcome{} = outcome) do
    %{
      "ok" => Outcome.ok?(outcome),
      "status" => Atom.to_string(outcome.status),
      "text" => outcome_text(outcome)
    }
  end

  defp outcome_text(%Outcome{status: :ok} = outcome), do: Outcome.answer(outcome) || ""

  defp outcome_text(%Outcome{} = outcome), do: Outcome.message(outcome)

  # Argument and context helpers --------------------------------------------------

  defp run_ref!(state, run) do
    case Lua.decode!(state, run) do
      {:userdata, %RunRef{} = run_ref} -> run_ref
      _other -> runtime_exception!("expected a run handle returned by tackle.spawn")
    end
  end

  defp context!(state) do
    case Lua.get_private(state, :tackle_script) do
      {:ok, context} -> context
      :error -> runtime_exception!("script runtime context is unavailable")
    end
  end
end
