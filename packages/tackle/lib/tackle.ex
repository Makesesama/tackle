defmodule Tackle do
  @moduledoc """
  Tackle — a small, provider-agnostic agent harness for Elixir.

  Tackle gives you the stateless core of an LLM agent: a ReAct-style loop, a
  tool-calling convention, system-prompt machinery, and pluggable behaviours.
  It deliberately owns *no* persistence, *no* concrete tools, and *no* provider
  SDK — the host application supplies those. This keeps Tackle KISS and lets it
  drop into an existing app without forcing a framework onto it.

  ## What Tackle provides

    * `Tackle.Loop` — the ReAct loop (think → act → repeat → answer).
    * `Tackle.State` — in-memory conversation/run state.
    * `Tackle.Snapshot` — immutable per-turn configuration baseline (tools,
      hooks, LLM config, version IDs).
    * `Tackle.Hook` — typed lifecycle hooks (before_prompt, after_prompt,
      before_tool_call, after_tool_call, after_turn).
    * `Tackle.Message` — conversation message value struct.
    * `Tackle.Tool` — the tool behaviour the loop calls.
    * `Tackle.Tool.Schema` — provider-neutral tool argument validation/coercion.
    * `Tackle.JSON` — configurable JSON behaviour with a built-in default adapter.
    * `Tackle.SystemPrompt` — response-format contract + tool-doc assembly.
    * `Tackle.Usage` — normalized token/cost metadata for LLM steps.
    * `Tackle.Event` — provider-independent run/message/tool/usage events.
    * `Tackle.LLM` — the provider-agnostic LLM behaviour (the keystone seam).
    * `Tackle.Tool.Adapters.*` — small adapters that make public runtime boundaries
      explicit, such as `Tackle.Tool.Adapters.Web.wrap/1` for agent tools.
    * `Tackle.Integrations.*` — optional glue for exposing tools through other
      protocols/runtimes such as Anubis MCP.

  ## What the host provides

    * An LLM adapter implementing `Tackle.LLM` (configured via
      `config :tackle, llm: MyApp.Adapter`).
    * Optionally, a JSON adapter implementing `Tackle.JSON` (configured via
      `config :tackle, json: MyApp.JSONAdapter`; defaults to `Tackle.JSON.Default`).
    * Concrete tools defined with `use Tackle.Tool` or manually implementing the
      `Tackle.Tool` callbacks.
    * A composed system prompt (domain model, workflows, etc.).
    * Any persistence/session storage it needs.

  ## Usage

      state =
        Tackle.new(
          model: "anthropic/claude-sonnet-4",
          tools: Tackle.Tool.Adapters.Web.wrap([MyApp.Tools.Search, MyApp.Tools.Fetch]),
          system_prompt: MyApp.build_system_prompt(),
          context: %{user_id: user.id}
        )

      {:ok, state} = Tackle.run(state, "How many videos are available?")
      Tackle.last_answer(state)
  """

  alias Tackle.Loop
  alias Tackle.Message
  alias Tackle.State

  @doc """
  Creates a new agent state. See `Tackle.State.new/1` for options.
  """
  defdelegate new(opts \\ []), to: State

  @doc """
  Runs the agent for a user query.

  ## Options
    * `:event_callback` - Function called with `%Tackle.Event{}` structs.
    * `:llm_stream` - When true, use `Tackle.LLM.stream/4` if configured adapter supports it.
  """
  defdelegate run(state, user_input, opts \\ []), to: Loop

  @doc """
  Retries the loop against existing state without appending a new user message.
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
  Derives aggregate token/cost usage for the current run/session.
  """
  @spec usage(State.t()) :: Tackle.Usage.t()
  defdelegate usage(state), to: State

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
