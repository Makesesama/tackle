defmodule Tackle.Lib.State do
  @moduledoc """
  State struct for the ReAct-style agent workflow.

  Tracks conversation messages, iteration count, status, and configuration.

  Tackle.Lib is host-driven: there are no default tools and no default model baked
  in. The host application passes the tool modules and model spec it wants. This
  keeps Tackle.Lib domain-agnostic — it knows how to run a loop, not which tools or
  models exist.

  A state carries only what outlives a turn and what hosts read: the loop's
  own per-step bookkeeping (the id of the assistant message being generated,
  the overflow recoveries spent) lives with the running turn, never here.
  Values that can be derived are not stored twice: `tools/1` reads the tool
  registry and `last_compaction_id/1` reads the tree or the model projection.

  A turn that ends in an error leaves a human-readable message in `:error` and
  the structured reason behind it in `:error_reason`, the same term the turn's
  `:error` event reports as `:reason` (for example the provider's error reason,
  such as a `Tackle.Lib.LLM.Error`, a hook's abort reason, `:max_iterations`,
  or `:empty_response`). Hosts match on `:error_reason`; `:error` is
  for people. A cancelled turn keeps its cancellation reason in `:error`. Both
  are cleared when the next turn starts (`reset_turn/1`).
  """

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Hook
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
          tool_registry: Registry.t(),
          tool_policy: Policy.t(),
          context: map(),
          llm: Selection.t() | nil,
          system_prompt: String.t() | nil,
          prompt_renderer: module() | nil,
          prompt_renderer_opts: keyword(),
          llm_opts: keyword(),
          id_generator: ID.generator(),
          hooks: [module()],
          error: String.t() | nil,
          error_reason: term(),
          retry: Retry.t(),
          compaction: Compaction.Config.t() | nil,
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
            tool_registry: Registry.new([]),
            tool_policy: Policy.default(),
            context: %{},
            llm: nil,
            system_prompt: nil,
            prompt_renderer: nil,
            prompt_renderer_opts: [],
            llm_opts: [],
            id_generator: &ID.uuid4/0,
            hooks: [],
            error: nil,
            error_reason: nil,
            retry: Retry.new!(),
            compaction: nil,
            tree: nil,
            tree_committer: nil

  @doc """
  Creates a new agent state with the given options.

  ## Options
    * `:llm` - The `Tackle.Lib.LLM.Selection` the loop generates with (see
      `Tackle.Lib.LLM.select/2`). A state without one can be built, inspected,
      and restored, but `Tackle.Lib.Loop` raises `ArgumentError` when asked to
      run it. The model is the selection's (`model/1`); a separate `:model`
      option raises `ArgumentError`.
    * `:max_iterations` - Maximum ReAct loop iterations per turn (default: `:infinity`)
    * `:tools` - List of tool modules implementing `Tackle.Lib.Tool` (default: []),
      built into `state.tool_registry`; `tools/1` returns them
    * `:tool_policy` - Tool execution policy (defaults to sequential Tackle.Lib policy)
    * `:context` - Additional context map (user info, permissions, etc.)
    * `:system_prompt` - Custom system prompt (overrides the built default)
    * `:prompt_renderer` - Prompt renderer used for response schema resolution
    * `:prompt_renderer_opts` - Options passed to the prompt renderer
    * `:llm_opts` - Extra options passed through to the LLM adapter
    * `:hooks` - List of Tackle.Lib.Hook modules for lifecycle callbacks (default: []);
      raises `ArgumentError` for an entry that is not a loadable module exporting
      a hook callback (see `Tackle.Lib.Hook.validate!/1`)
    * `:id_generator` - Zero-arity function used for generated ids
    * `:session_id` - Existing session id to install without invoking `:id_generator`
    * `:retry` - `Tackle.Lib.Retry`, options, `false`, or `nil` (default: three
      retries with deterministic exponential backoff starting at 2 seconds)
    * `:compaction` - `Tackle.Lib.Compaction.Config`, options, `false`, or `nil`
      (default: `nil`, compaction disabled)
    * `:tree` - `true`, a `Tackle.Lib.Tree`, or `nil`/`false` (default: `nil`).
      `true` enables an opt-in conversation tree with branching history. When
      given an existing tree, the active transcript and model context are
      reconstructed from its selected path.
    * `:tree_committer` - module implementing `Tackle.Lib.Tree.Committer` used
      to persist navigation before it is installed (default: `nil`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id_generator = Keyword.get(opts, :id_generator, &ID.uuid4/0)

    llm = llm!(opts)

    tree = normalize_tree(Keyword.get(opts, :tree))

    %__MODULE__{
      session_id: Keyword.get(opts, :session_id) || id_generator.(),
      messages: if(tree, do: Tree.transcript(tree), else: []),
      model_messages: if(tree, do: Tree.model_context(tree), else: nil),
      current_iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      status: :idle,
      tool_registry: Registry.new(Keyword.get(opts, :tools, [])),
      tool_policy: Keyword.get(opts, :tool_policy, Policy.default()),
      context: Keyword.get(opts, :context, %{}),
      llm: llm,
      system_prompt: Keyword.get(opts, :system_prompt),
      prompt_renderer: Keyword.get(opts, :prompt_renderer),
      prompt_renderer_opts: Keyword.get(opts, :prompt_renderer_opts, []),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      id_generator: id_generator,
      hooks: Hook.validate!(Keyword.get(opts, :hooks, [])),
      error: nil,
      error_reason: nil,
      retry: normalize_retry(Keyword.get(opts, :retry)),
      compaction: normalize_compaction(Keyword.get(opts, :compaction)),
      tree: tree,
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

  # A selection names its own model, so a separate `:model` could only be
  # ignored or contradict it.
  defp llm!(opts) do
    if Keyword.has_key?(opts, :model) do
      raise ArgumentError,
            "the model comes from the :llm selection; pass a Tackle.Lib.LLM.Selection " <>
              "instead of :model (got model: #{inspect(Keyword.get(opts, :model))})"
    end

    case Keyword.get(opts, :llm) do
      nil ->
        nil

      %Selection{} = selection ->
        selection

      other ->
        raise ArgumentError,
              "expected :llm to be a Tackle.Lib.LLM.Selection, got: #{inspect(other)}"
    end
  end

  @doc """
  Returns the adapter-local model of the state's selection, or `nil` without
  one.
  """
  @spec model(t()) :: String.t() | nil
  def model(%__MODULE__{llm: %Selection{model: model}}), do: model
  def model(%__MODULE__{}), do: nil

  @doc """
  Clears the per-turn fields so a new turn starts clean: the iteration
  counter, the status (back to `:idle`), and the previous turn's `:error` and
  `:error_reason`.

  The loop calls it when a turn starts; hosts call it when they install a
  conversation (a restored session, a navigated tree) on a state that may
  have run before. The conversation and the configuration are kept.
  """
  @spec reset_turn(t()) :: t()
  def reset_turn(%__MODULE__{} = state) do
    %{state | current_iteration: 0, status: :idle, error: nil, error_reason: nil}
  end

  @doc """
  Returns the configured tool modules, in the order they were given to `new/1`.
  """
  @spec tools(t()) :: [module()]
  def tools(%__MODULE__{tool_registry: registry}), do: Registry.modules(registry)

  @doc """
  Adds a message to the conversation history.

  In linear mode the canonical transcript always receives the message and the
  model projection is kept in step: while it mirrors the transcript (`nil`) it
  stays mirrored, and once compaction has replaced it the message is appended
  explicitly.

  In tree mode the message is appended to the active position and the existing
  projections are extended. Navigation and restoration reconstruct projections
  from the selected tree path.
  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{tree: %Tree{} = tree} = state, %Message{} = message) do
    case Tree.append_message(tree, message) do
      {:ok, tree, _entry} ->
        %{
          state
          | tree: tree,
            messages: state.messages ++ [message],
            model_messages: model_messages(state) ++ [message]
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
  Returns the usage on the active conversation, split where compactions
  rewrote the model context.

  Each list holds, oldest first, the `token_usage` of the messages in one
  span over which the context only grew; a compaction starts the next span.
  `Tackle.Lib.Usage.cache_reuse/1` takes these spans, since comparing prompts
  across a rewrite would count the rewritten prefix as a cache miss. Earlier
  spans without usage are left out, but the last span is always the current
  one, empty right after a compaction, so usage that arrives next (such as a
  running turn's) can be appended to it without joining the span before the
  compaction.

  In tree mode the spans follow the compaction entries on the active path.
  Linear mode knows only the latest compaction (the head of the model
  projection), so the spans before it come back as one.
  """
  @spec usage_segments(t()) :: [[Usage.t() | map()]]
  def usage_segments(%__MODULE__{tree: %Tree{} = tree}) do
    tree
    |> Tree.active_path()
    |> Enum.reduce([[]], fn
      %Tree.Entry{kind: :compaction}, segments ->
        [[] | segments]

      %Tree.Entry{kind: :message, message: message}, [segment | rest] ->
        [[message | segment] | rest]
    end)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> message_usages()))
    |> keep_current_span()
  end

  def usage_segments(%__MODULE__{} = state) do
    segments =
      case last_compaction_id(state) do
        nil ->
          [state.messages]

        _id ->
          # The model projection's retained copies lost their usage; messages
          # still carrying it there arrived after the compaction.
          current =
            for %Message{id: id, token_usage: usage} <- state.model_messages,
                not is_nil(usage),
                into: MapSet.new(),
                do: id

          {later, earlier} = Enum.split_with(state.messages, &MapSet.member?(current, &1.id))
          [earlier, later]
      end

    segments |> Enum.map(&message_usages/1) |> keep_current_span()
  end

  defp keep_current_span(segments) do
    {earlier, [current]} = Enum.split(segments, -1)
    Enum.reject(earlier, &(&1 == [])) ++ [current]
  end

  defp message_usages(messages) do
    for %Message{token_usage: usage} <- messages, not is_nil(usage), do: usage
  end

  @doc """
  Returns the most recent compaction id on the active path, or nil.

  In tree mode it is the latest compaction entry on the active path. In
  linear mode it is the id of the checkpoint message that a compaction puts
  at the head of the model projection, which is the compaction's id.
  """
  @spec last_compaction_id(t()) :: String.t() | nil
  def last_compaction_id(%__MODULE__{tree: %Tree{} = tree}), do: Tree.last_compaction_id(tree)

  def last_compaction_id(%__MODULE__{model_messages: [%Message{id: id} = first | _rest]}) do
    if Compaction.checkpoint?(first), do: id
  end

  def last_compaction_id(%__MODULE__{}), do: nil

  # Loop-internal: how the loop ends a turn. `message` is the human-readable
  # `:error`, and `reason` the structured `:error_reason` behind it, or `nil`.
  @doc false
  @spec set_error(t(), String.t(), term()) :: t()
  def set_error(%__MODULE__{} = state, message, reason \\ nil) do
    %{state | status: :error, error: message, error_reason: reason}
  end

  # Loop-internal: the cancellation reason is kept in `:error`;
  # `:error_reason` is cleared.
  @doc false
  @spec set_cancelled(t(), String.t()) :: t()
  def set_cancelled(%__MODULE__{} = state, reason) do
    %{state | status: :cancelled, error: reason, error_reason: nil}
  end
end
