defmodule Tackle.State do
  @moduledoc """
  State struct for the ReAct-style agent workflow.

  Tracks conversation messages, iteration count, status, and configuration.

  Tackle is host-driven: there are no default tools and no default model baked
  in. The host application passes the tool modules and model spec it wants. This
  keeps Tackle domain-agnostic — it knows how to run a loop, not which tools or
  models exist.
  """

  alias Tackle.Message
  alias Tackle.Tool.Policy
  alias Tackle.Tool.Registry
  alias Tackle.Usage

  @type status :: :idle | :thinking | :acting | :completed | :error | :cancelled

  @type t :: %__MODULE__{
          session_id: String.t(),
          messages: [Message.t()],
          current_iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          status: status(),
          tools: [module()],
          tool_registry: Registry.t(),
          tool_policy: Policy.t(),
          context: map(),
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          prompt_renderer: module() | nil,
          prompt_renderer_opts: keyword(),
          llm_opts: keyword(),
          id_generator: Tackle.ID.generator(),
          hooks: [module()],
          snapshot: Tackle.Snapshot.t() | nil,
          error: String.t() | nil,
          pending_assistant_id: String.t() | nil
        }

  @default_max_iterations 10

  defstruct session_id: nil,
            messages: [],
            current_iteration: 0,
            max_iterations: @default_max_iterations,
            status: :idle,
            tools: [],
            tool_registry: Registry.new([]),
            tool_policy: Policy.default(),
            context: %{},
            model: nil,
            system_prompt: nil,
            prompt_renderer: nil,
            prompt_renderer_opts: [],
            llm_opts: [],
            id_generator: &Tackle.ID.uuid4/0,
            hooks: [],
            snapshot: nil,
            error: nil,
            pending_assistant_id: nil

  @doc """
  Creates a new agent state with the given options.

  ## Options
    * `:model` - The LLM model spec to use (host-supplied; no default)
    * `:max_iterations` - Maximum ReAct loop iterations (default: 10)
    * `:tools` - List of tool modules implementing `Tackle.Tool` (default: [])
    * `:tool_policy` - Tool execution policy (defaults to sequential Tackle policy)
    * `:context` - Additional context map (user info, permissions, etc.)
    * `:system_prompt` - Custom system prompt (overrides the built default)
    * `:prompt_renderer` - Prompt renderer used for response schema resolution
    * `:prompt_renderer_opts` - Options passed to the prompt renderer
    * `:llm_opts` - Extra options passed through to the LLM adapter
    * `:hooks` - List of Tackle.Hook modules for lifecycle callbacks (default: [])
    * `:id_generator` - Zero-arity function used for generated ids
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id_generator = Keyword.get(opts, :id_generator, &Tackle.ID.uuid4/0)

    tools = Keyword.get(opts, :tools, [])

    %__MODULE__{
      session_id: id_generator.(),
      messages: [],
      current_iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      status: :idle,
      tools: tools,
      tool_registry: Registry.new(tools),
      tool_policy: Keyword.get(opts, :tool_policy, Policy.default()),
      context: Keyword.get(opts, :context, %{}),
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      prompt_renderer: Keyword.get(opts, :prompt_renderer),
      prompt_renderer_opts: Keyword.get(opts, :prompt_renderer_opts, []),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      id_generator: id_generator,
      hooks: Keyword.get(opts, :hooks, []),
      snapshot: nil,
      error: nil,
      pending_assistant_id: nil
    }
  end

  @doc """
  Adds a message to the conversation history.
  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{} = state, %Message{} = message) do
    %{state | messages: state.messages ++ [message]}
  end

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
  def max_iterations_reached?(%__MODULE__{} = state) do
    state.current_iteration >= state.max_iterations
  end

  @doc """
  Derives aggregate token/cost usage for the current run/session.

  Tackle does not persist sessions, but `State` is the in-memory session/run
  representation. Usage is derived from assistant messages so messages remain
  the source of truth and no running total can drift.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{} = state) do
    state.messages
    |> Enum.map(& &1.token_usage)
    |> Usage.aggregate()
  end

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
