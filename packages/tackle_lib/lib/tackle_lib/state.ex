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
  registry and `last_compaction_id/1` reads the tree.

  ## Conversation

  The conversation is always a `Tackle.Lib.Tree` (`:tree`): every settled
  message and every committed compaction is an entry, and one entry is the
  active position. A state that never navigates is simply a tree with one
  branch. Whether a host lets its users branch is host policy; the library
  can always navigate (`Tackle.Lib.navigate/3`).

  `:messages` (the active path's complete transcript) and `:model_messages`
  (the active path's provider context, with its compactions applied) are
  cached derivations of the tree, kept so the loop and hosts read them
  without walking the tree. They are written only together with the tree:
  `add_message/2` extends them, and `put_tree/2` installs a tree and
  re-derives both. Never set them directly; a state whose caches disagree
  with its tree sends one history and records another.

  A turn that ends in an error leaves a human-readable message in `:error` and
  the structured reason behind it in `:error_reason`, the same term the turn's
  `:error` event reports as `:reason` (for example the provider's error reason,
  such as a `Tackle.Lib.LLM.Error`, a hook's abort reason, `:max_iterations`,
  or `:empty_response`). Hosts match on `:error_reason`; `:error` is
  for people. A cancelled turn keeps its cancellation reason in `:error`. Both
  are cleared when the next turn starts (`reset_turn/1`).
  """

  alias Tackle.Lib.Committer
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
          model_messages: [Message.t()],
          current_iteration: non_neg_integer(),
          max_iterations: iteration_limit(),
          status: status(),
          tool_registry: Registry.t(),
          tool_policy: Policy.t(),
          context: map(),
          llm: Selection.t() | nil,
          system_prompt: String.t() | nil,
          llm_opts: keyword(),
          id_generator: ID.generator(),
          hooks: [module()],
          error: String.t() | nil,
          error_reason: term(),
          retry: Retry.t(),
          compaction: Compaction.Config.t() | nil,
          tree: Tree.t(),
          committer: module() | nil
        }

  @default_max_iterations :infinity

  defstruct session_id: nil,
            messages: [],
            model_messages: [],
            current_iteration: 0,
            max_iterations: @default_max_iterations,
            status: :idle,
            tool_registry: Registry.new([]),
            tool_policy: Policy.default(),
            context: %{},
            llm: nil,
            system_prompt: nil,
            llm_opts: [],
            id_generator: &ID.uuid4/0,
            hooks: [],
            error: nil,
            error_reason: nil,
            retry: Retry.new!(),
            compaction: nil,
            tree: %Tree{},
            committer: nil

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
    * `:llm_opts` - Extra options passed through to the LLM adapter
    * `:hooks` - List of Tackle.Lib.Hook modules for lifecycle callbacks (default: []);
      raises `ArgumentError` for an entry that is not a loadable module exporting
      a hook callback (see `Tackle.Lib.Hook.validate!/1`)
    * `:id_generator` - Zero-arity function used for generated ids
    * `:session_id` - Existing session id to install without invoking `:id_generator`
    * `:retry` - `Tackle.Lib.Retry`, options, `false`, or `nil` (default: three
      retries with deterministic exponential backoff starting at 2 seconds)
    * `:compaction` - a `Tackle.Lib.Compaction.Config` or its options, or
      `nil` (the default), which disables compaction
    * `:tree` - an existing `Tackle.Lib.Tree` to continue (default: an empty
      tree); its active transcript and model context are derived from its
      selected path (see `put_tree/2`)
    * `:committer` - module implementing `Tackle.Lib.Committer`, which makes
      compactions and navigations durable before they are installed
      (default: `nil`, in memory only); raises `ArgumentError` for a module
      that is not loaded or does not export `commit/2`
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id_generator = Keyword.get(opts, :id_generator, &ID.uuid4/0)

    llm = llm!(opts)

    state = %__MODULE__{
      session_id: Keyword.get(opts, :session_id) || id_generator.(),
      current_iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      status: :idle,
      tool_registry: Registry.new(Keyword.get(opts, :tools, [])),
      tool_policy: Keyword.get(opts, :tool_policy, Policy.default()),
      context: Keyword.get(opts, :context, %{}),
      llm: llm,
      system_prompt: Keyword.get(opts, :system_prompt),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      id_generator: id_generator,
      hooks: Hook.validate!(Keyword.get(opts, :hooks, [])),
      error: nil,
      error_reason: nil,
      retry: normalize_retry(Keyword.get(opts, :retry)),
      compaction: normalize_compaction(Keyword.get(opts, :compaction)),
      committer: committer!(Keyword.get(opts, :committer))
    }

    case Keyword.get(opts, :tree) do
      nil ->
        state

      %Tree{} = tree ->
        put_tree(state, tree)

      other ->
        raise ArgumentError, "expected :tree to be a Tackle.Lib.Tree, got: #{inspect(other)}"
    end
  end

  defp normalize_retry(value) do
    case Retry.new(value) do
      {:ok, retry} -> retry
      {:error, reason} -> raise ArgumentError, "invalid :retry config: #{inspect(reason)}"
    end
  end

  defp normalize_compaction(nil), do: nil

  defp normalize_compaction(config)
       when is_struct(config, Compaction.Config) or is_list(config) do
    case Compaction.Config.new(config) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid :compaction config: #{inspect(reason)}"
    end
  end

  defp normalize_compaction(other) do
    raise ArgumentError,
          "expected :compaction to be a config, options, or nil, got: #{inspect(other)}"
  end

  defp committer!(committer) do
    case Committer.validate(committer) do
      :ok -> committer
      {:error, reason} -> raise ArgumentError, "invalid :committer: #{inspect(reason)}"
    end
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
  Adds a settled message to the conversation.

  The message is appended to the tree at the active position, which it
  becomes, and to the cached transcript and model context. Raises
  `ArgumentError` when the tree refuses the message, such as one without an
  id or with an id already in the tree.
  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{tree: tree} = state, %Message{} = message) do
    case Tree.append_message(tree, message) do
      {:ok, tree, _entry} ->
        %{
          state
          | tree: tree,
            messages: state.messages ++ [message],
            model_messages: state.model_messages ++ [message]
        }

      {:error, reason} ->
        raise ArgumentError, "cannot append message to conversation tree: #{inspect(reason)}"
    end
  end

  @doc """
  Installs `tree` as the state's conversation.

  The cached transcript (`:messages`) and model context (`:model_messages`)
  are re-derived from the tree's active path, so they always agree with it.
  This is the one way to install a tree: a restored session, a navigation,
  and a compaction all go through it. The turn fields are left alone; call
  `reset_turn/1` when installing a conversation on a state that may have run
  before.
  """
  @spec put_tree(t(), Tree.t()) :: t()
  def put_tree(%__MODULE__{} = state, %Tree{} = tree) do
    %{
      state
      | tree: tree,
        messages: Tree.transcript(tree),
        model_messages: Tree.model_context(tree)
    }
  end

  @doc """
  Replaces one settled message, keeping its place in the conversation.

  `fun` receives the message and returns its replacement, which must keep the
  message's id (`ArgumentError` otherwise). The tree entry is updated and the
  cached transcript and model context re-derived, so hosts that amend a
  message after a turn (attaching usage the provider reported separately,
  say) keep the tree consistent. Returns `{:error, {:unknown_message, id}}`
  when no message entry has the id.
  """
  @spec update_message(t(), String.t(), (Message.t() -> Message.t())) ::
          {:ok, t()} | {:error, {:unknown_message, String.t()}}
  def update_message(%__MODULE__{tree: tree} = state, id, fun) when is_function(fun, 1) do
    case Tree.update_message(tree, id, fun) do
      {:ok, tree} -> {:ok, put_tree(state, tree)}
      {:error, _reason} -> {:error, {:unknown_message, id}}
    end
  end

  @doc """
  Returns the provider-visible model context: the active path's messages with
  its compactions applied, a checkpoint followed by the recent tail after one.
  """
  @spec model_messages(t()) :: [Message.t()]
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

  This covers the complete archive: every settled assistant message is
  counted once even when branches share it. Use `branch_usage/1` for the
  active path.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{tree: tree}), do: Tree.usage(tree)

  @doc """
  Derives token/cost usage for the active conversation path only.

  A conversation that never branched has a single path, so this equals
  `usage/1`.
  """
  @spec branch_usage(t()) :: Usage.t()
  def branch_usage(%__MODULE__{tree: tree}), do: Tree.branch_usage(tree)

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

  The spans follow the compaction entries on the active path.
  """
  @spec usage_segments(t()) :: [[Usage.t() | map()]]
  def usage_segments(%__MODULE__{tree: tree}) do
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

  defp keep_current_span(segments) do
    {earlier, [current]} = Enum.split(segments, -1)
    Enum.reject(earlier, &(&1 == [])) ++ [current]
  end

  defp message_usages(messages) do
    for %Message{token_usage: usage} <- messages, not is_nil(usage), do: usage
  end

  @doc """
  Returns the most recent committed compaction on the active path, or nil.

  Its `summary_message` is the checkpoint at the head of `model_messages/1`.
  Checkpoints are known by their compaction entries in the tree, never by
  their content, so a user message that happens to look like one is still a
  user message.
  """
  @spec last_compaction(t()) :: Compaction.Record.t() | nil
  def last_compaction(%__MODULE__{tree: tree}), do: Tree.last_compaction(tree)

  @doc "Returns the id of the most recent compaction on the active path, or nil."
  @spec last_compaction_id(t()) :: String.t() | nil
  def last_compaction_id(%__MODULE__{tree: tree}), do: Tree.last_compaction_id(tree)

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
