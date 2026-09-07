defmodule Tackle.Lib.Hook do
  @moduledoc """
  Typed lifecycle hooks for the Tackle.Lib agent loop.

  Hooks let hosts observe and mutate agent behaviour at well-defined lifecycle
  points without modifying the loop itself. Every callback is optional — a hook
  module implements only the events it cares about.

  ## Lifecycle events (in order per turn)

    1. `before_prompt/2` — before the LLM prompt is assembled.
    2. `after_prompt/2`  — after the LLM response is received and parsed.
    3. `before_tool_call/3` — before each individual tool call is executed.
    4. `after_tool_call/3`  — after each tool call settles (success or error).
    5. `after_message/3` — after an assistant/tool/user message is finalized and emitted.
    6. `after_turn/2`       — after the turn completes (success, error, or cancel).

  ## Return conventions

    * `:ok` — observer-only; the hook read state but made no changes.
    * `{:ok, context}` — mutator; the returned context map replaces the current
      run context for subsequent steps.
    * `{:error, reason}` — abort; the turn is halted with the given error reason.

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
  Called after the LLM responds and the response is parsed into structured data.

  Receives the current state, the parsed response map (usually plain `content`
  and/or provider-native `tool_calls`), and the run context. The hook fires
  before the loop dispatches tool calls or final-answer logic.
  """
  @callback after_prompt(state :: State.t(), response :: map(), context :: map()) ::
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
                      after_turn: 2

  @doc """
  Invokes a lifecycle callback across all configured hook modules.

  Returns `{:ok, context}` where context may have been updated by mutator hooks.
  Returns `{:error, reason}` if any hook aborted.
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

  defp apply_hook(hook_module, event, args, acc_context) do
    full_args = args ++ [acc_context]
    arity = length(full_args)

    if function_exported?(hook_module, event, arity) do
      hook_module
      |> apply(event, full_args)
      |> handle_hook_result(hook_module, event, full_args, acc_context)
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
