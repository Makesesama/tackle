defmodule Tackle.Lib.State do
  @moduledoc """
  State struct for the ReAct-style agent workflow.

  Tracks conversation messages, iteration count, status, and configuration.

  Tackle.Lib is host-driven: there are no default tools and no default model baked
  in. The host application passes the tool modules and model spec it wants. This
  keeps Tackle.Lib domain-agnostic — it knows how to run a loop, not which tools or
  models exist.
  """

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.ID
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Retry
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Usage

  @type status :: :idle | :thinking | :acting | :completed | :error | :cancelled
  @type iteration_limit :: pos_integer() | :infinity

  @type t :: %__MODULE__{
          session_id: String.t(),
          messages: [Message.t()],
          model_messages: [Message.t()] | nil,
          current_iteration: non_neg_integer(),
          max_iterations: iteration_limit(),
          status: status(),
          tools: [module()],
          tool_registry: Registry.t(),
          tool_policy: Policy.t(),
          context: map(),
          llm: Selection.t() | nil,
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          prompt_renderer: module() | nil,
          prompt_renderer_opts: keyword(),
          llm_opts: keyword(),
          id_generator: ID.generator(),
          hooks: [module()],
          snapshot: Tackle.Lib.Snapshot.t() | nil,
          error: String.t() | nil,
          pending_assistant_id: String.t() | nil,
          retry: Retry.t(),
          compaction: Compaction.Config.t() | nil,
          last_compaction_id: String.t() | nil,
          overflow_retries: non_neg_integer(),
          tree: Tree.t() | nil,
          tree_committer: module() | nil
        }

  @default_max_iterations :infinity

  defstruct session_id: nil,
            messages: [],
            model_messages: nil,
            current_iteration: 0,
            max_iterations: @default_max_iterations,
            status: :idle,
            tools: [],
            tool_registry: Registry.new([]),
            tool_policy: Policy.default(),
            context: %{},
            llm: nil,
            model: nil,
            system_prompt: nil,
            prompt_renderer: nil,
            prompt_renderer_opts: [],
            llm_opts: [],
            id_generator: &ID.uuid4/0,
            hooks: [],
            snapshot: nil,
            error: nil,
            pending_assistant_id: nil,
            retry: Retry.new!(),
            compaction: nil,
            last_compaction_id: nil,
            overflow_retries: 0,
            tree: nil,
            tree_committer: nil

  @doc """
  Creates a new agent state with the given options.

  ## Options
    * `:model` - The LLM model spec to use (host-supplied; no default)
    * `:max_iterations` - Maximum ReAct loop iterations (default: `:infinity`)
    * `:tools` - List of tool modules implementing `Tackle.Lib.Tool` (default: [])
    * `:tool_policy` - Tool execution policy (defaults to sequential Tackle.Lib policy)
    * `:context` - Additional context map (user info, permissions, etc.)
    * `:llm` - A `Tackle.Lib.LLM.Selection` for per-state adapter selection
    * `:system_prompt` - Custom system prompt (overrides the built default)
    * `:prompt_renderer` - Prompt renderer used for response schema resolution
    * `:prompt_renderer_opts` - Options passed to the prompt renderer
    * `:llm_opts` - Extra options passed through to the LLM adapter
    * `:hooks` - List of Tackle.Lib.Hook modules for lifecycle callbacks (default: [])
    * `:id_generator` - Zero-arity function used for generated ids
    * `:session_id` - Existing session id to install without invoking `:id_generator`
    * `:retry` - `Tackle.Lib.Retry`, options, `false`, or `nil` (default: three
      retries with deterministic exponential backoff starting at 2 seconds)
    * `:compaction` - `Tackle.Lib.Compaction.Config`, options, `false`, or `nil`
      (default: `nil`, compaction disabled)
    * `:tree` - `true`, a `Tackle.Lib.Tree`, or `nil`/`false` (default: `nil`).
      `true` enables an opt-in conversation tree with branching history.
    * `:tree_committer` - module implementing `Tackle.Lib.Tree.Committer` used
      to persist navigation before it is installed (default: `nil`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id_generator = Keyword.get(opts, :id_generator, &ID.uuid4/0)

    tools = Keyword.get(opts, :tools, [])
    llm = validate_llm_selection!(Keyword.get(opts, :llm))
    model = if llm, do: llm.model, else: Keyword.get(opts, :model)

    %__MODULE__{
      session_id: Keyword.get(opts, :session_id) || id_generator.(),
      messages: [],
      current_iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      status: :idle,
      tools: tools,
      tool_registry: Registry.new(tools),
      tool_policy: Keyword.get(opts, :tool_policy, Policy.default()),
      context: Keyword.get(opts, :context, %{}),
      llm: llm,
      model: model,
      system_prompt: Keyword.get(opts, :system_prompt),
      prompt_renderer: Keyword.get(opts, :prompt_renderer),
      prompt_renderer_opts: Keyword.get(opts, :prompt_renderer_opts, []),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      id_generator: id_generator,
      hooks: Keyword.get(opts, :hooks, []),
      snapshot: nil,
      error: nil,
      pending_assistant_id: nil,
      retry: normalize_retry(Keyword.get(opts, :retry)),
      compaction: normalize_compaction(Keyword.get(opts, :compaction)),
      tree: normalize_tree(Keyword.get(opts, :tree)),
      tree_committer: Keyword.get(opts, :tree_committer)
    }
  end

  defp normalize_tree(nil), do: nil
  defp normalize_tree(false), do: nil
  defp normalize_tree(true), do: Tree.new()
  defp normalize_tree(%Tree{} = tree), do: tree

  defp normalize_tree(other) do
    raise ArgumentError,
          "expected :tree to be true, a Tackle.Lib.Tree, false, or nil, got: #{inspect(other)}"
  end

  defp normalize_retry(value) do
    case Retry.new(value) do
      {:ok, retry} -> retry
      {:error, reason} -> raise ArgumentError, "invalid :retry config: #{inspect(reason)}"
    end
  end

  defp normalize_compaction(nil), do: nil

  defp normalize_compaction(%Compaction.Config{} = config) do
    case Compaction.Config.new(config) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid :compaction config: #{inspect(reason)}"
    end
  end

  defp normalize_compaction(opts) when is_list(opts) or is_boolean(opts) do
    case Compaction.Config.new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid :compaction config: #{inspect(reason)}"
    end
  end

  defp normalize_compaction(other) do
    raise ArgumentError,
          "expected :compaction to be a config, options, false, or nil, got: #{inspect(other)}"
  end

  defp validate_llm_selection!(nil), do: nil
  defp validate_llm_selection!(%Selection{} = selection), do: selection

  defp validate_llm_selection!(selection) do
    raise ArgumentError,
          "expected :llm to be a Tackle.Lib.LLM.Selection, got: #{inspect(selection)}"
  end

  @doc """
  Adds a message to the conversation history.

  In linear mode the canonical transcript always receives the message and the
  model projection is kept in step: while it mirrors the transcript (`nil`) it
  stays mirrored, and once compaction has replaced it the message is appended
  explicitly.

  In tree mode the message is appended to the active position and the transcript
  and model-context readers are re-derived from the tree.
  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{tree: %Tree{} = tree} = state, %Message{} = message) do
    case Tree.append_message(tree, message) do
      {:ok, tree, _entry} ->
        %{
          state
          | tree: tree,
            messages: Tree.transcript(tree),
            model_messages: Tree.model_context(tree)
        }

      {:error, reason} ->
        raise ArgumentError, "cannot append message to conversation tree: #{inspect(reason)}"
    end
  end

  def add_message(%__MODULE__{} = state, %Message{} = message) do
    %{
      state
      | messages: state.messages ++ [message],
        model_messages: append_model(state.model_messages, message)
    }
  end

  defp append_model(nil, _message), do: nil
  defp append_model(model_messages, message), do: model_messages ++ [message]

  @doc """
  Returns the provider-visible model message projection.

  `nil` means the projection mirrors the complete settled transcript; after a
  compaction the projection is an explicit `[checkpoint | recent tail]` list.
  """
  @spec model_messages(t()) :: [Message.t()]
  def model_messages(%__MODULE__{model_messages: nil, messages: messages}), do: messages
  def model_messages(%__MODULE__{model_messages: model_messages}), do: model_messages

  @doc """
  Updates the agent status.
  """
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = state, status) do
    %{state | status: status}
  end

  @doc """
  Increments the iteration counter.
  """
  @spec increment_iteration(t()) :: t()
  def increment_iteration(%__MODULE__{} = state) do
    %{state | current_iteration: state.current_iteration + 1}
  end

  @doc """
  Checks if the agent has exceeded max iterations.
  """
  @spec max_iterations_reached?(t()) :: boolean()
  def max_iterations_reached?(%__MODULE__{max_iterations: :infinity}), do: false

  def max_iterations_reached?(%__MODULE__{} = state) do
    state.current_iteration >= state.max_iterations
  end

  @doc """
  Derives aggregate token/cost usage for the current run/session.

  In tree mode this covers the complete archive: every settled assistant message
  is counted once even when branches share it. Use `branch_usage/1` for the
  active path.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{tree: %Tree{} = tree}), do: Tree.usage(tree)

  def usage(%__MODULE__{} = state) do
    state.messages
    |> Enum.map(& &1.token_usage)
    |> Usage.aggregate()
  end

  @doc """
  Derives token/cost usage for the active conversation path only.

  Linear mode has a single path, so this equals `usage/1`.
  """
  @spec branch_usage(t()) :: Usage.t()
  def branch_usage(%__MODULE__{tree: %Tree{} = tree}), do: Tree.branch_usage(tree)
  def branch_usage(%__MODULE__{} = state), do: usage(state)

  @doc """
  Returns the most recent compaction id on the active path, or nil.
  """
  @spec last_compaction_id(t()) :: String.t() | nil
  def last_compaction_id(%__MODULE__{tree: %Tree{} = tree}), do: Tree.last_compaction_id(tree)
  def last_compaction_id(%__MODULE__{last_compaction_id: id}), do: id

  @doc """
  Sets an error on the state.
  """
  @spec set_error(t(), String.t()) :: t()
  def set_error(%__MODULE__{} = state, error) do
    %{state | status: :error, error: error}
  end

  @doc """
  Marks the state as cancelled.
  """
  @spec set_cancelled(t(), String.t()) :: t()
  def set_cancelled(%__MODULE__{} = state, reason) do
    %{state | status: :cancelled, error: reason}
  end
end
