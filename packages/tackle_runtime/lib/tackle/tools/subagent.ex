defmodule Tackle.Tools.Subagent do
  @moduledoc """
  Opt-in tool that delegates one self-contained task to a fresh subagent.

  The subagent is an ordinary Tackle agent running the same `Tackle.Lib` loop in
  the same root scope. Foreground mode waits for its terminal outcome and
  returns the final answer. Background mode returns a stable run id immediately.
  Any terminal outcome automatically notifies and continues the parent once it
  is idle; use `subagent_wait` to block for the result sooner or
  `subagent_status` to inspect or collect it later. The child session remains
  one-shot and stops after its first terminal result.

  Delegation is opt-in and permissioned:

    * the host must add this module to a session's tool list;
    * the running agent must carry a runtime handle with delegation granted;
    * the requested profile must be allowlisted in the scope spec.

  Model-visible arguments can only name an allowlisted profile; they can never
  name a module, widen limits, or address a process.
  """

  use Tackle.Lib.Tool

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome

  tool_name("subagent")

  description(
    "Delegate a self-contained task to a fresh subagent. By default this waits and returns " <>
      "the final answer. Use background=true only for independent work. After a background " <>
      "launch, do not repeat the delegated task: continue only non-overlapping work or use " <>
      "subagent_wait to block. The parent is automatically notified on any terminal outcome; " <>
      "subagent_status checks or collects without waiting. Choose one configured profile. " <>
      "The one-shot child cannot receive more work after it finishes."
  )

  input do
    field(:profile, :string,
      required: true,
      description: "Name of the allowlisted subagent profile to run"
    )

    field(:prompt, :string, required: true, description: "Self-contained task for the subagent")

    field(:background, :boolean,
      default: false,
      description: "Return immediately with a run id instead of waiting for completion"
    )

    field(:timeout_ms, :integer,
      description: "Optional maximum wait in milliseconds, bounded by the scope run timeout"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"profile" => profile, "prompt" => prompt} = args, context)
      when is_binary(profile) and is_binary(prompt) do
    with {:ok, handle} <- fetch_handle(context),
         :ok <- ensure_delegation(handle),
         {:ok, opts} <- timeout_opts(args, handle),
         opts = put_callbacks(opts, context, args),
         opts = put_retention(opts, context, args),
         {:ok, run_ref} <- request(handle, profile, prompt, opts) do
      emit(context, :subagent_started, run_ref, profile)
      finish(args, run_ref, profile, context)
    end
  end

  def run(_args, _context), do: {:error, "subagent requires a profile and a prompt"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "subagent is unavailable: this agent has no runtime handle"}
    end
  end

  defp ensure_delegation(%Handle{allow_delegation: true}), do: :ok

  defp ensure_delegation(%Handle{}),
    do: {:error, "subagent delegation is not permitted for this agent"}

  defp timeout_opts(args, %Handle{limits: limits}) do
    case Map.get(args, "timeout_ms") do
      nil ->
        {:ok, []}

      ms when is_integer(ms) and ms > 0 ->
        max = if limits, do: limits.run_timeout, else: ms
        {:ok, [timeout: min(ms, max)]}

      _other ->
        {:error, "timeout_ms must be a positive integer"}
    end
  end

  defp put_callbacks(opts, context, args) do
    background? = Map.get(args, "background", false)
    opts = put_event_callback(opts, context, Map.get(args, "profile"), background?)

    if background? do
      opts
      |> Keyword.put(:completion_message, &completion_message/2)
      |> Keyword.put(:launch_message, &launch_message/1)
    else
      opts
    end
  end

  defp put_event_callback(opts, context, profile, background?) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        tool_call_id = Map.get(context, :tool_call_id)

        Keyword.put(opts, :event_callback, fn run_ref, child_event ->
          callback.(
            Event.new(:subagent_progress, %{
              run_id: run_ref.run_id,
              agent_ref: run_ref.agent_ref,
              tool_call_id: tool_call_id,
              profile: profile,
              model: run_ref.model_ref,
              background: background?,
              event: child_event
            })
          )
        end)

      _other ->
        opts
    end
  end

  defp put_retention(opts, context, %{"background" => true}) do
    opts
    |> Keyword.put(:owner, :parent)
    |> Keyword.put(:retention, :until_collected)
    |> put_origin(context)
  end

  defp put_retention(opts, _context, _args), do: opts

  defp put_origin(opts, %{runtime_turn_id: turn_id, tool_call_id: tool_call_id})
       when is_binary(turn_id) and turn_id != "" and is_binary(tool_call_id) and
              tool_call_id != "" do
    Keyword.put(opts, :origin, %{turn_id: turn_id, tool_call_id: tool_call_id})
  end

  defp put_origin(opts, _context), do: opts

  defp finish(%{"background" => true}, run_ref, _profile, _context) do
    {:ok, launch_message(run_ref)}
  end

  defp finish(_args, run_ref, profile, context) do
    outcome = Runtime.await(run_ref, :infinity)
    emit(context, :subagent_finished, run_ref, profile, outcome)
    handle_outcome(outcome)
  end

  defp launch_message(run_ref) do
    "Started background subagent #{run_ref.run_id}. Do not repeat its assignment. Continue only " <>
      "with non-overlapping work; otherwise use subagent_wait with this run_id to block for and " <>
      "collect its result. You will be notified when it finishes, or use subagent_status to " <>
      "check without waiting."
  end

  defp completion_message(run_ref, %Outcome{status: :ok}) do
    "Background subagent #{run_ref.run_id} completed. Use subagent_status to collect its result."
  end

  defp completion_message(run_ref, %Outcome{} = outcome) do
    "Background subagent #{run_ref.run_id} finished with #{Outcome.message(outcome)}. " <>
      "Use subagent_status to collect its result."
  end

  defp request(handle, profile, prompt, opts) do
    case Runtime.request_agent(handle, profile, prompt, opts) do
      {:ok, run_ref} -> {:ok, run_ref}
      {:error, {:rejected, reason}} -> {:error, "subagent rejected: #{inspect(reason)}"}
      {:error, {:unknown_profile, name}} -> {:error, "unknown subagent profile: #{name}"}
      {:error, reason} -> {:error, "could not start subagent: #{inspect(reason)}"}
    end
  end

  defp emit(context, type, run_ref, profile, outcome \\ nil) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        data = %{
          run_id: run_ref.run_id,
          agent_ref: run_ref.agent_ref,
          tool_call_id: Map.get(context, :tool_call_id),
          profile: profile,
          model: run_ref.model_ref,
          status: outcome_status(outcome)
        }

        callback.(Event.new(type, data))

      _other ->
        :ok
    end
  end

  defp outcome_status(nil), do: :running
  defp outcome_status(%Outcome{status: status}), do: status
  defp outcome_status({:error, _reason}), do: :runtime_error

  defp handle_outcome(%Outcome{status: :ok} = outcome),
    do: {:ok, Outcome.answer(outcome) || "(subagent produced no answer)"}

  defp handle_outcome(%Outcome{status: :error} = outcome),
    do: {:error, "subagent failed: #{Outcome.message(outcome)}"}

  defp handle_outcome(%Outcome{status: :cancelled}), do: {:error, "subagent was cancelled"}
  defp handle_outcome(%Outcome{status: :timeout}), do: {:error, "subagent timed out"}

  defp handle_outcome(%Outcome{status: :runtime_error} = outcome),
    do: {:error, "subagent crashed: #{Outcome.message(outcome)}"}

  defp handle_outcome(%Outcome{} = outcome),
    do: {:error, "subagent ended: #{Outcome.message(outcome)}"}

  defp handle_outcome({:error, reason}),
    do: {:error, "subagent is unavailable: #{inspect(reason)}"}
end
