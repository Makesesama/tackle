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

  ## Configuring hooks

  A state's `:hooks` is a list of modules, each implementing at least one
  callback. `Tackle.Lib.State.new/1` and every turn when it starts check
  them with `validate!/1` and raise `ArgumentError` for any other entry, such
  as a misspelled module, so a hook is never skipped silently.

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
        llm: selection,
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
  The hook can inspect the call, update the context with `{:ok, context}`, or
  veto the call with `{:error, reason}`, which ends the turn with that reason
  before the call runs. The loop dispatches the call it passed in: a hook
  cannot change the call or its arguments.
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

  @typedoc """
  A lifecycle event `invoke/4` runs: a callback name other than
  `before_turn_end`, which `invoke_before_turn_end/3` runs.
  """
  @type event ::
          :before_prompt
          | :after_prompt
          | :before_tool_call
          | :after_tool_call
          | :after_message
          | :after_turn

  # Events by the arguments `invoke/4` passes before the context: the state,
  # or the state and the event's subject (response, call, result, message).
  @state_events [:before_prompt, :after_turn]
  @subject_events [:after_prompt, :before_tool_call, :after_tool_call, :after_message]

  @callbacks [before_turn_end: 2] ++
               Enum.map(@state_events, &{&1, 2}) ++ Enum.map(@subject_events, &{&1, 3})

  @doc """
  Returns true when `module` is a hook: a module that can be loaded and that
  exports at least one `Tackle.Lib.Hook` callback.
  """
  @spec hook?(term()) :: boolean()
  def hook?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.any?(@callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  def hook?(_module), do: false

  @doc """
  Validates a list of hook modules and returns it.

  Raises `ArgumentError` unless `hooks` is a list in which every entry passes
  `hook?/1`, so a misspelled or unloadable module fails when the hooks are
  configured instead of skipping every callback, a safety gate included.
  """
  @spec validate!(term()) :: [module()]
  def validate!(hooks) when is_list(hooks) do
    case Enum.reject(hooks, &hook?/1) do
      [] ->
        hooks

      invalid ->
        raise ArgumentError,
              "expected :hooks to be modules implementing at least one Tackle.Lib.Hook " <>
                "callback, got invalid entries: #{inspect(invalid)}"
    end
  end

  def validate!(hooks) do
    raise ArgumentError, "expected :hooks to be a list of modules, got: #{inspect(hooks)}"
  end

  @doc """
  Invokes a lifecycle callback across all configured hook modules.

  `args` are the callback's arguments before the context. Hooks run in order,
  each receiving the context returned by the previous one. Returns
  `{:ok, context}` where context may have been updated by mutator hooks, or
  `{:error, reason}` if a hook aborted, crashed, or returned an unexpected
  value, without running the hooks after it. An event outside `t:event/0`,
  or `args` of the wrong length for it, raises `FunctionClauseError`. Use
  `invoke_before_turn_end/3` for `before_turn_end/2`, whose hooks can also
  continue the turn.
  """
  @spec invoke(hooks :: [module()], event :: event(), args :: [term()], context :: map()) ::
          {:ok, map()} | {:error, term()}
  def invoke(hooks, event, args, context)
      when is_list(hooks) and is_list(args) and
             ((event in @state_events and length(args) == 1) or
                (event in @subject_events and length(args) == 2)) do
    case run(hooks, event, args, context) do
      {:ok, context, []} -> {:ok, context}
      {:error, _reason} = error -> error
    end
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
    run(hooks, :before_turn_end, [state], context)
  end

  defp run(hooks, event, args, context) do
    hooks
    |> Enum.reduce_while({:ok, context, []}, fn hook_module, {:ok, acc_context, acc_messages} ->
      case apply_hook(hook_module, event, args, acc_context) do
        {:ok, new_context, messages} -> {:cont, {:ok, new_context, [messages | acc_messages]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, context, messages} -> {:ok, context, messages |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp apply_hook(hook_module, event, args, context) do
    callback = {event, length(args) + 1}

    if implements?(hook_module, callback) do
      case call_hook(hook_module, callback, args ++ [context]) do
        {:ok, result} -> handle_result(result, hook_module, callback, context)
        {:crashed, reason} -> {:error, reason}
      end
    else
      {:ok, context, []}
    end
  end

  defp handle_result(:ok, _hook_module, _callback, context), do: {:ok, context, []}

  defp handle_result({:ok, new_context}, _hook_module, _callback, _context)
       when is_map(new_context),
       do: {:ok, new_context, []}

  defp handle_result({:error, _reason} = error, _hook_module, _callback, _context), do: error

  defp handle_result(
         {:continue, messages},
         hook_module,
         {:before_turn_end, _} = callback,
         context
       ),
       do: continue_with(messages, context, hook_module, callback)

  defp handle_result(
         {:continue, messages, new_context},
         hook_module,
         {:before_turn_end, _} = callback,
         _context
       )
       when is_map(new_context),
       do: continue_with(messages, new_context, hook_module, callback)

  defp handle_result(other, hook_module, callback, _context) do
    {:error,
     "Hook #{describe(hook_module, callback)} returned unexpected value: #{inspect(other)}"}
  end

  defp continue_with(messages, context, hook_module, callback) do
    if is_list(messages) and Enum.all?(messages, &(is_binary(&1) and &1 != "")) do
      {:ok, context, messages}
    else
      {:error,
       "Hook #{describe(hook_module, callback)} returned invalid messages " <>
         "(expected non-empty strings): #{inspect(messages)}"}
    end
  end

  # `function_exported?/3` is false for a module that is not loaded yet, which
  # in interactive mode (tests, `mix run`, IEx) would skip a hook silently.
  defp implements?(hook_module, {event, arity}) do
    Code.ensure_loaded?(hook_module) and function_exported?(hook_module, event, arity)
  end

  # A hook that raises, throws, or exits aborts like one returning an error, so
  # the loop still settles the turn instead of crashing with it.
  defp call_hook(hook_module, {event, _arity} = callback, args) do
    {:ok, apply(hook_module, event, args)}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Hook ",
          describe(hook_module, callback),
          " crashed: ",
          Exception.format(kind, reason, stacktrace)
        ]
      end)

      {:crashed,
       "Hook #{describe(hook_module, callback)} crashed: " <>
         String.replace_prefix(Exception.format_banner(kind, reason, stacktrace), "** ", "")}
  end

  defp describe(hook_module, {event, arity}), do: "#{inspect(hook_module)}.#{event}/#{arity}"
end
