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
    * `Tackle.Lib.Cancellation` — cooperative cancellation signals for runs,
      adapters, and tools.
    * `Tackle.Lib.CredentialStore` — provider-neutral access through host-owned handles.
    * `Tackle.Lib.Interaction` — frontend-supplied handle adapters use to show
      instructions or ask for input, for example during a login flow.
    * `Tackle.Lib.SystemPrompt` — a small builder for markdown system prompts.
    * `Tackle.Lib.Usage` — normalized token/cost metadata for LLM steps.
    * `Tackle.Lib.ModelInfo` — adapter-owned model limits and price cards.
    * `Tackle.Lib.ContextUsage` — context-window pressure and token estimates.
    * `Tackle.Lib.Event` — provider-independent run/message/tool/usage events.
    * `Tackle.Lib.Retry` — bounded transient-provider retries with cancellable
      exponential backoff.
    * `Tackle.Lib.LLM` — the provider-agnostic LLM behaviour and explicit
      adapter/model selection (the keystone seam).
    * `Tackle.Lib.Decision` — optional contract for small local decision
      models that answer typed questions with probabilities.
    * `Tackle.Lib.Thinking` — provider-neutral thinking levels.
    * `Tackle.Lib.Telemetry` — exporter-neutral lifecycle telemetry spans.
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

  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree.Navigator

  @doc """
  Creates a new agent state. See `Tackle.Lib.State.new/1` for options.
  """
  @spec new(keyword()) :: State.t()
  defdelegate new(opts \\ []), to: State

  @doc """
  Runs the agent for a user query.

  See `Tackle.Lib.Loop.run/3` for the options and results.
  """
  @spec run(State.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  defdelegate run(state, user_input, opts \\ []), to: Loop

  @doc """
  Runs a turn against the existing state without appending a user message.

  See `Tackle.Lib.Loop.continue/2`; it takes the same options as `run/3`.
  """
  @spec continue(State.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  defdelegate continue(state, opts \\ []), to: Loop

  @doc """
  Returns the final answer the conversation ends with, or `nil`.

  That is the content of the last message when it is a final answer
  (`Tackle.Lib.Message.final_answer?/1`): an assistant message with content
  and no tool calls. A conversation that ends otherwise, for example with an
  assistant message that also requested tools, with tool results, or with a
  user message after a failed or cancelled turn, has no answer, and an
  earlier turn's answer is not returned in its place.
  """
  @spec last_answer(State.t()) :: String.t() | nil
  def last_answer(%State{messages: messages}) do
    case List.last(messages) do
      %Message{content: content} = message ->
        if Message.final_answer?(message), do: content

      nil ->
        nil
    end
  end

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
end
