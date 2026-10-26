defmodule Tackle.Lib.Hook do
  @moduledoc """
  Typed lifecycle hooks for the Tackle.Lib agent loop.

  Hooks let hosts observe and mutate agent behaviour at well-defined lifecycle
  points without modifying the loop itself. Every callback is optional — a hook
  module implements only the events it cares about.

  ## Lifecycle events (in order per turn)

    1. `before_prompt/2` — before the LLM prompt is assembled.
    2. `after_prompt/3`  — after the step's LLM response is received and
       normalized into a `Tackle.Lib.LLM.Response`.
    3. `before_tool_call/3` — before each individual tool call is executed.
    4. `after_tool_call/3`  — after each tool call settles (success or error).
    5. `after_message/3` — after an assistant/tool/user message is finalized and emitted.
    6. `before_turn_end/2`  — after a final answer, before the turn completes; can
       continue the turn with feedback (see "Gating the end of a turn").
    7. `after_turn/2`       — after the turn completes (success, error, or cancel).

  ## Return conventions

    * `:ok` — observer-only; the hook read state but made no changes.
    * `{:ok, context}` — mutator; the returned context map replaces the current
      run context for subsequent steps.
    * `{:error, reason}` — abort; the turn is halted with the given error reason,
      which the turn's state keeps as `error_reason` (see `Tackle.Lib.State`).

  A hook that raises, throws, or exits aborts the turn the same way, with a
  reason describing the crash. Crashes in `after_turn/2` are logged and
  otherwise ignored, like its errors.

  `before_turn_end/2` may also return `{:continue, messages}` or
  `{:continue, messages, context}`.

  ## Gating the end of a turn

  `before_turn_end/2` lets a hook check the agent's work before the turn
  completes, for example by compiling the project. It runs when the model has
  given a final answer and the host has no queued incoming messages. Returning
  `{:continue, messages}` appends each message (a non-empty string) as a user
  message and continues the same turn, so the model can repair its work; an
  empty list completes the turn like `:ok`. When several hooks run, their
  messages are appended in hook order.

  The loop does not limit how often a hook continues a turn beyond the state's
  `max_iterations`, which ends the turn with an error. A gate should count its
  own rounds in the context and stop continuing after a few, and can reset the
  count in `after_turn/2`. Report problems neutrally rather than ordering the
  model to fix every one of them.

  ## Cancellation

  When the run has a cancellation signal, every callback except `after_turn/2`
  receives it in its context as `:cancellation_signal`. A slow hook, such as a
  gate that compiles the project, should check it with
  `Tackle.Lib.Cancellation.cancelled?/1` and stop early. The signal belongs to
  the run: the loop does not keep it in the state's context.

  ## Example

      defmodule MyApp.Hooks.AuditLogger do
        @behaviour Tackle.Lib.Hook

        @impl true
        def after_turn(state, _context) do
          MyApp.Audit.log(:agent_turn, state.session_id, state.status)
          :ok
        end
      end

      state = Tackle.Lib.new(
        model: "anthropic/claude-sonnet-4",
        hooks: [MyApp.Hooks.AuditLogger],
        context: %{user_id: user.id}
      )
  """

  require Logger

  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error
  alias Tackle.Lib.Tool.Result

  @doc """
  Called before the LLM prompt is assembled for this iteration.

  Receives the current agent state and run context. The prompt has not yet been
  built, so the hook can inspect the tool list, conversation, and context but
  cannot modify the prompt text directly.
  """
  @callback before_prompt(state :: State.t(), context :: map()) ::
              :ok | {:ok, map()} | {:error, term()}

  @doc """
  Called after the LLM responds, with the response the step keeps.

  Receives the current state, the normalized `Tackle.Lib.LLM.Response` (its
  `content`, `thinking`, `tool_calls` as `Tackle.Lib.Tool.Call` structs, and
  `usage`), and the run context. The hook fires once per step, after the
  step's `:step_end` event and before the loop dispatches tool calls or the
  final answer. It never sees an empty response the loop asked again, nor a
  malformed result, which ends the turn before the hook runs.
  """
  @callback after_prompt(state :: State.t(), response :: Response.t(), context :: map()) ::
              :ok | {:ok, map()} | {:error, term()}

  @doc """
  Called before an individual tool call is executed.

  Receives the current state, the normalized tool call, and the run context.
  The hook can inspect or enrich the call arguments before dispatch.
  """
  @callback before_tool_call(state :: State.t(), call :: Call.t(), context :: map()) ::
              :ok | {:ok, map()} | {:error, term()}

  @doc """
  Called after a tool call settles (success or error).

  Receives the current state, the settlement result (either `%Result{}` or
  `%Error{}`), and the run context. The hook can log, record metrics, or modify
  the context for subsequent steps.
  """
  @callback after_tool_call(
              state :: State.t(),
              result :: Result.t() | Error.t(),
              context :: map()
            ) :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Called after a message has been settled and emitted.

  Receives the current state, the message that just completed, and run context.
  Implementations can persist the message or mutate context. This callback is
  intentionally display-agnostic and runs for user, assistant, and tool messages.
  """
  @callback after_message(
              state :: State.t(),
              message :: Message.t(),
              context :: map()
            ) :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Called after the model gives a final answer, before the turn completes.

  Receives the current state, whose last message is the final assistant
  message, and the run context. Not called for turns that end in an error,
  cancellation, or the iteration limit. Return `{:continue, messages}` or
  `{:continue, messages, context}` to append `messages` as user messages and
  continue the turn; see "Gating the end of a turn" in the module docs.
  """
  @callback before_turn_end(state :: State.t(), context :: map()) ::
              :ok
              | {:ok, map()}
              | {:continue, [String.t()]}
              | {:continue, [String.t()], map()}
              | {:error, term()}

  @doc """
  Called after the turn completes, regardless of outcome.

  Receives the final state (with status `:completed`, `:error`, or `:cancelled`)
  and the run context. This is the canonical teardown hook for audit, metrics,
  and cleanup.
  """
  @callback after_turn(state :: State.t(), context :: map()) ::
              :ok | {:ok, map()} | {:error, term()}

  @optional_callbacks before_prompt: 2,
                      after_prompt: 3,
                      before_tool_call: 3,
                      after_tool_call: 3,
                      after_message: 3,
                      before_turn_end: 2,
                      after_turn: 2

  @doc """
  Invokes a lifecycle callback across all configured hook modules.

  Returns `{:ok, context}` where context may have been updated by mutator hooks.
  Returns `{:error, reason}` if any hook aborted. Use
  `invoke_before_turn_end/3` for `before_turn_end/2`, whose hooks can also
  continue the turn.
  """
  @spec invoke(
          hooks :: [module()],
          event :: atom(),
          args :: [term()],
          context :: map()
        ) :: {:ok, map()} | {:error, term()}
  def invoke(hooks, event, args, context) when is_list(hooks) and is_atom(event) do
    Enum.reduce_while(hooks, {:ok, context}, fn hook_module, {:ok, acc_context} ->
      apply_hook(hook_module, event, args, acc_context)
    end)
  end

  @doc """
  Invokes `before_turn_end/2` across all configured hook modules.

  Hooks run in order, each receiving the context returned by the previous one.
  Returns `{:ok, context, messages}` with the messages of every hook that
  returned `{:continue, ...}`, in hook order; an empty list means the turn may
  complete. Returns `{:error, reason}` if a hook aborted or returned an
  unexpected value, without running the hooks after it.
  """
  @spec invoke_before_turn_end(hooks :: [module()], state :: State.t(), context :: map()) ::
          {:ok, map(), [String.t()]} | {:error, term()}
  def invoke_before_turn_end(hooks, %State{} = state, context) when is_list(hooks) do
    hooks
    |> Enum.reduce_while({:ok, context, []}, fn hook_module, {:ok, acc_context, acc_messages} ->
      case apply_before_turn_end(hook_module, state, acc_context) do
        {:ok, new_context, messages} -> {:cont, {:ok, new_context, [messages | acc_messages]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, context, messages} -> {:ok, context, messages |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp apply_before_turn_end(hook_module, state, context) do
    if implements?(hook_module, :before_turn_end, 2) do
      case call_hook(hook_module, :before_turn_end, [state, context]) do
        {:ok, result} -> handle_before_turn_end_result(result, hook_module, context)
        {:crashed, reason} -> {:error, reason}
      end
    else
      {:ok, context, []}
    end
  end

  defp handle_before_turn_end_result(:ok, _hook_module, context), do: {:ok, context, []}

  defp handle_before_turn_end_result({:ok, new_context}, _hook_module, _context)
       when is_map(new_context),
       do: {:ok, new_context, []}

  defp handle_before_turn_end_result({:continue, messages}, hook_module, context),
    do: continue_with(messages, context, hook_module)

  defp handle_before_turn_end_result({:continue, messages, new_context}, hook_module, _context)
       when is_map(new_context),
       do: continue_with(messages, new_context, hook_module)

  defp handle_before_turn_end_result({:error, _reason} = error, _hook_module, _context),
    do: error

  defp handle_before_turn_end_result(other, hook_module, _context) do
    {:error,
     "Hook #{inspect(hook_module)}.before_turn_end/2 returned unexpected value: #{inspect(other)}"}
  end

  defp continue_with(messages, context, hook_module) do
    if is_list(messages) and Enum.all?(messages, &(is_binary(&1) and &1 != "")) do
      {:ok, context, messages}
    else
      {:error,
       "Hook #{inspect(hook_module)}.before_turn_end/2 returned invalid messages " <>
         "(expected non-empty strings): #{inspect(messages)}"}
    end
  end

  # `function_exported?/3` is false for a module that is not loaded yet, which
  # in interactive mode (tests, `mix run`, IEx) would skip a hook silently.
  defp implements?(hook_module, event, arity) do
    Code.ensure_loaded?(hook_module) and function_exported?(hook_module, event, arity)
  end

  # A hook that raises, throws, or exits aborts like one returning an error, so
  # the loop still settles the turn instead of crashing with it.
  defp call_hook(hook_module, event, args) do
    {:ok, apply(hook_module, event, args)}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Hook ",
          inspect(hook_module),
          ".#{event}/#{length(args)} crashed: ",
          Exception.format(kind, reason, stacktrace)
        ]
      end)

      {:crashed,
       "Hook #{inspect(hook_module)}.#{event}/#{length(args)} crashed: " <>
         String.replace_prefix(Exception.format_banner(kind, reason, stacktrace), "** ", "")}
  end

  defp apply_hook(hook_module, event, args, acc_context) do
    full_args = List.insert_at(args, -1, acc_context)
    arity = length(full_args)

    if implements?(hook_module, event, arity) do
      case call_hook(hook_module, event, full_args) do
        {:ok, result} -> handle_hook_result(result, hook_module, event, full_args, acc_context)
        {:crashed, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, acc_context}}
    end
  end

  defp handle_hook_result(:ok, _hook_module, _event, _full_args, acc_context) do
    {:cont, {:ok, acc_context}}
  end

  defp handle_hook_result({:ok, new_context}, _hook_module, _event, _full_args, _acc_context)
       when is_map(new_context) do
    {:cont, {:ok, new_context}}
  end

  defp handle_hook_result(
         {:error, _reason} = error,
         _hook_module,
         _event,
         _full_args,
         _acc_context
       ) do
    {:halt, error}
  end

  defp handle_hook_result(other, hook_module, event, full_args, _acc_context) do
    {:halt,
     {:error,
      "Hook #{inspect(hook_module)}.#{event}/#{length(full_args)} returned unexpected value: #{inspect(other)}"}}
  end
end
