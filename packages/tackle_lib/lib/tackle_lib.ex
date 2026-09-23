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
      before_tool_call, after_tool_call, after_turn).
    * `Tackle.Lib.Message` — conversation message value struct.
    * `Tackle.Lib.Compaction` — checkpoint compaction of the provider-visible
      model projection, with pluggable summarizers and an optional durability
      committer.
    * `Tackle.Lib.Tool` — the tool behaviour the loop calls.
    * `Tackle.Lib.Tool.Schema` — provider-neutral tool argument validation/coercion.
    * `Tackle.Lib.JSON` — configurable JSON behaviour with a built-in default adapter.
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
      or configured as one compatible application-wide default.
    * Optionally, a JSON adapter implementing `Tackle.Lib.JSON` (configured via
      `config :tackle_lib, json: MyApp.JSONAdapter`; defaults to `Tackle.Lib.JSON.Default`).
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
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Navigator

  @doc """
  Creates a new agent state. See `Tackle.Lib.State.new/1` for options.
  """
  defdelegate new(opts \\ []), to: State

  @doc """
  Runs the agent for a user query.

  ## Options
    * `:event_callback` - Function called with `%Tackle.Lib.Event{}` structs.
    * `:llm_stream` - When true, use the optional `stream/3` callback in `Tackle.Lib.LLM` if the configured adapter supports it.
    * `:turn_id` - Host-assigned turn id stored on the per-turn snapshot.
  """
  defdelegate run(state, user_input, opts \\ []), to: Loop

  @doc """
  Retries the loop against existing state without appending a new user message.

  Accepts the same execution options as `run/3`, including a host-assigned
  `:turn_id`.
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
  shares the exact transaction, validation, and durability rules. Returns the
  updated state and the durable `Tackle.Lib.Compaction.Record`.
  """
  @spec compact(State.t(), keyword()) ::
          {:ok, State.t(), Tackle.Lib.Compaction.Record.t()}
          | {:error | :cancelled, term()}
          | {:error | :cancelled, term(), State.t()}
  def compact(%State{} = state, opts \\ []), do: Compaction.compact(state, :manual, opts)

  @doc """
  Derives aggregate token/cost usage for the current run/session.
  """
  @spec usage(State.t()) :: Tackle.Lib.Usage.t()
  defdelegate usage(state), to: State

  @doc """
  Derives token/cost usage for the active conversation path only.

  Linear mode has a single path, so this equals `usage/1`. In tree mode it
  excludes sibling branches.
  """
  @spec branch_usage(State.t()) :: Tackle.Lib.Usage.t()
  defdelegate branch_usage(state), to: State

  @doc """
  Returns the conversation tree, or `nil` when tree history is disabled.
  """
  @spec tree(State.t()) :: Tree.t() | nil
  def tree(%State{tree: tree}), do: tree

  @doc """
  Navigates the active position of an opt-in tree session.

  The library prepares the transition against the tree's current revision,
  validates the destination, and commits through the configured
  `Tackle.Lib.Tree.Committer` before installing the new position. Navigation
  never runs a turn, re-executes a tool, or modifies entries.

  Targets are described in `Tackle.Lib.Tree.Navigator`. Expected failures
  include `:tree_disabled`, `{:unknown_entry, id}`, `{:unsafe_continuation,
  id}`, `{:stale_transition, expected, actual}`, and
  `{:durable_commit_failed, reason}`. A failed validation or commit leaves the
  accepted state unchanged.
  """
  @spec navigate(State.t(), Navigator.target(), keyword()) ::
          {:ok, State.t(), Navigator.outcome()} | {:error, term()}
  def navigate(%State{} = state, target, opts \\ []) do
    case state.tree do
      nil ->
        {:error, :tree_disabled}

      %Tree{} = tree ->
        navigate_tree(state, tree, target, opts)
    end
  end

  defp navigate_tree(%State{} = state, tree, target, opts) do
    if active?(state) do
      {:error, :turn_in_progress}
    else
      with {:ok, outcome} <- Navigator.navigate(tree, target, opts),
           :ok <- commit_navigation(state, outcome.change, opts) do
        {:ok, install_navigation(state, outcome), outcome}
      end
    end
  end

  # The library refuses to navigate a state that is visibly mid-turn. Immutable
  # state cannot know about another process executing a copy, so the host must
  # still serialize turns, navigation, and compaction.
  defp active?(%State{status: status}), do: status in [:thinking, :acting]

  defp commit_navigation(_state, nil, _opts), do: :ok

  defp commit_navigation(%State{} = state, change, opts) do
    case Keyword.get(opts, :committer) || state.tree_committer do
      nil ->
        :ok

      module ->
        commit_with(module, change, state)
    end
  end

  defp commit_with(module, change, state) do
    case module.commit_navigation(change, %{session_id: state.session_id, context: state.context}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:durable_commit_failed, reason}}
      other -> {:error, {:durable_commit_failed, {:unexpected_commit_result, other}}}
    end
  rescue
    error -> {:error, {:durable_commit_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:durable_commit_failed, {kind, reason}}}
  end

  defp install_navigation(%State{} = state, outcome) do
    tree = outcome.tree

    %{
      state
      | tree: tree,
        messages: Tree.transcript(tree),
        model_messages: Tree.model_context(tree),
        last_compaction_id: Tree.last_compaction_id(tree),
        current_iteration: 0,
        status: :idle,
        error: nil,
        pending_assistant_id: nil,
        snapshot: nil,
        overflow_retries: 0
    }
  end

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
