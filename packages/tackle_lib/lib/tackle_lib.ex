defmodule Tackle.Lib do
  @moduledoc """
  Tackle.Lib — a small, provider-agnostic agent harness for Elixir.

  Tackle.Lib gives you the stateless core of an LLM agent: a ReAct-style loop, a
  tool-calling convention, system-prompt machinery, and pluggable behaviours.
  It deliberately owns *no* persistence, *no* concrete tools, and *no* provider
  SDK — the host application supplies those. This keeps Tackle.Lib KISS and lets it
  drop into an existing app without forcing a framework onto it.

  ## What Tackle.Lib provides

    * `Tackle.Lib.Loop` — the ReAct loop (think → act → repeat → answer).
    * `Tackle.Lib.State` — in-memory conversation/run state.
    * `Tackle.Lib.Snapshot` — immutable per-turn configuration baseline (tools,
      hooks, LLM config, version IDs).
    * `Tackle.Lib.Hook` — typed lifecycle hooks (before_prompt, after_prompt,
      before_tool_call, after_tool_call, after_message, before_turn_end,
      after_turn).
    * `Tackle.Lib.Message` — conversation message value struct.
    * `Tackle.Lib.Compaction` — checkpoint compaction of the provider-visible
      model projection, with pluggable summarizers.
    * `Tackle.Lib.Tree` — the conversation history every state keeps, which
      can branch: `navigate/3` moves its active position.
    * `Tackle.Lib.Committer` — the durability seam compactions and
      navigations commit through before they are installed.
    * `Tackle.Lib.Tool` — the tool behaviour the loop calls.
    * `Tackle.Lib.Tool.Schema` — provider-neutral tool argument validation/coercion.
    * `Tackle.Lib.CredentialStore` — provider-neutral access through host-owned handles.
    * `Tackle.Lib.SystemPrompt` — response-format contract + tool-doc assembly.
    * `Tackle.Lib.Usage` — normalized token/cost metadata for LLM steps.
    * `Tackle.Lib.ModelInfo` — adapter-owned model limits and price cards.
    * `Tackle.Lib.ContextUsage` — context-window pressure and token estimates.
    * `Tackle.Lib.Event` — provider-independent run/message/tool/usage events.
    * `Tackle.Lib.Retry` — bounded transient-provider retries with cancellable
      exponential backoff.
    * `Tackle.Lib.LLM` — the provider-agnostic LLM behaviour and explicit
      adapter/model selection (the keystone seam).
    * `Tackle.Lib.Integrations.Registry` — provider-neutral registry for exposing
      tools through host-owned bridges (for example `Tackle.Anubis`).

  ## What the host provides

    * One or more LLM adapters implementing `Tackle.Lib.LLM`, selected per state
      with `Tackle.Lib.LLM.select/2`.
    * Concrete tools defined with `use Tackle.Lib.Tool` or manually implementing the
      `Tackle.Lib.Tool` callbacks.
    * A composed system prompt (domain model, workflows, etc.).
    * Any persistence/session storage it needs.

  ## Usage

      {:ok, llm} =
        Tackle.Lib.LLM.select([MyApp.AI.AnthropicAdapter], "anthropic/claude-sonnet-4")

      state =
        Tackle.Lib.new(
          llm: llm,
          tools: [MyApp.Tools.Search, MyApp.Tools.Fetch],
          system_prompt: MyApp.build_system_prompt(),
          context: %{user_id: user.id}
        )

      {:ok, state} = Tackle.Lib.run(state, "How many videos are available?")
      Tackle.Lib.last_answer(state)
  """

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree.Navigator

  @doc """
  Creates a new agent state. See `Tackle.Lib.State.new/1` for options.
  """
  defdelegate new(opts \\ []), to: State

  @doc """
  Runs the agent for a user query.

  ## Options

  Unknown options raise `ArgumentError`. See `Tackle.Lib.Loop.run/3` for details.

    * `:event_callback` - Function called with `%Tackle.Lib.Event{}` structs. Tools
      also receive it in their context as `:event_callback`.
    * `:tool_context` - Map merged over `state.context` for tool execution only.
    * `:llm_stream` - When true, use the optional `stream/3` callback in `Tackle.Lib.LLM` if the selected adapter supports it.
    * `:cancellation_signal` - `Tackle.Lib.Cancellation.Signal` checked between loop steps.
    * `:turn_id` - Host-assigned turn id stored on the per-turn snapshot.
    * `:tool_supervisor` - `Task.Supervisor` required by the `:concurrent` tool policy.
    * `:take_incoming_messages` - Zero-arity callback returning queued user messages.
    * `:before_provider_call` - Zero-arity gate run before every provider dispatch.
    * `:before_tool_execution` - Zero-arity gate run before tools with external effects.
  """
  defdelegate run(state, user_input, opts \\ []), to: Loop

  @doc """
  Retries the loop against existing state without appending a new user message.

  Accepts the same options as `run/3`, including a host-assigned `:turn_id`;
  unknown options raise `ArgumentError`. Like `run/3`, it captures a fresh
  snapshot of the state's configuration for the turn.
  """
  defdelegate continue(state, opts \\ []), to: Loop

  @doc """
  Gets the last assistant answer from the conversation, or nil.
  """
  @spec last_answer(State.t()) :: String.t() | nil
  def last_answer(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, content: content} when is_binary(content) and content != "" ->
        content

      _ ->
        nil
    end)
  end

  @doc """
  Gets all messages from the conversation.
  """
  @spec messages(State.t()) :: [Message.t()]
  def messages(%State{messages: messages}), do: messages

  @doc """
  Returns the provider-visible model message projection.

  Before compaction this mirrors `messages/1`; after compaction it is a
  synthetic checkpoint followed by a verbatim recent tail. The canonical
  transcript is never modified by compaction.
  """
  @spec model_messages(State.t()) :: [Message.t()]
  defdelegate model_messages(state), to: State

  @doc """
  Runs one manual (idle) compaction of the model projection.

  Manual compaction bypasses the automatic pressure threshold but otherwise
  shares the exact transaction, validation, and durability rules of
  `Tackle.Lib.Compaction.compact/3`. Returns the updated state and the durable
  `Tackle.Lib.Compaction.Record`, or `{:error, reason, state}` /
  `{:cancelled, reason, state}` with the last committed state, such as
  `{:error, :nothing_to_compact, state}` when the projection already fits the
  policy's retention target.
  """
  @spec compact(State.t(), keyword()) :: Compaction.result()
  def compact(%State{} = state, opts \\ []), do: Compaction.compact(state, :manual, opts)

  @doc """
  Derives aggregate token/cost usage for the current run/session.
  """
  @spec usage(State.t()) :: Tackle.Lib.Usage.t()
  defdelegate usage(state), to: State

  @doc """
  Navigates the active position of the state's conversation tree.

  Commits the `Tackle.Lib.Tree.Change` through the state's
  `Tackle.Lib.Committer` before installing the new position. Targets, the
  `:expected_revision` option, and the errors are described in
  `Tackle.Lib.Tree.Navigator.navigate/3`.
  """
  @spec navigate(State.t(), Navigator.target(), keyword()) ::
          {:ok, State.t(), Navigator.Outcome.t()} | {:error, term()}
  defdelegate navigate(state, target, opts \\ []), to: Navigator

  @doc """
  Calculates current context-window usage for the selected model.

  Returns `nil` when the adapter does not declare a context window.
  """
  @spec context_usage(State.t()) :: Tackle.Lib.ContextUsage.t() | nil
  def context_usage(%State{} = state), do: ContextUsage.estimate(state)

  @doc """
  Checks if the agent has completed its task.
  """
  @spec completed?(State.t()) :: boolean()
  def completed?(%State{status: status}), do: status == :completed

  @doc """
  Checks if the agent encountered an error.
  """
  @spec error?(State.t()) :: boolean()
  def error?(%State{status: status}), do: status == :error

  @doc """
  Gets the error message if the agent errored, or nil.
  """
  @spec error(State.t()) :: String.t() | nil
  def error(%State{error: error}), do: error
end
