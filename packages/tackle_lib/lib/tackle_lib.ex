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
    * `Tackle.Lib.Tool` — the tool behaviour the loop calls.
    * `Tackle.Lib.Tool.Schema` — provider-neutral tool argument validation/coercion.
    * `Tackle.Lib.JSON` — configurable JSON behaviour with a built-in default adapter.
    * `Tackle.Lib.CredentialStore` — provider-neutral access through host-owned handles.
    * `Tackle.Lib.SystemPrompt` — response-format contract + tool-doc assembly.
    * `Tackle.Lib.Usage` — normalized token/cost metadata for LLM steps.
    * `Tackle.Lib.Event` — provider-independent run/message/tool/usage events.
    * `Tackle.Lib.LLM` — the provider-agnostic LLM behaviour and explicit
      adapter/model selection (the keystone seam).
    * `Tackle.Lib.Tool.Adapters.*` — small adapters that make public runtime boundaries
      explicit, such as `Tackle.Lib.Tool.Adapters.Web.wrap/1` for agent tools.
    * `Tackle.Lib.Integrations.*` — optional glue for exposing tools through other
      protocols/runtimes such as Anubis MCP.

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
          tools: Tackle.Lib.Tool.Adapters.Web.wrap([MyApp.Tools.Search, MyApp.Tools.Fetch]),
          system_prompt: MyApp.build_system_prompt(),
          context: %{user_id: user.id}
        )

      {:ok, state} = Tackle.Lib.run(state, "How many videos are available?")
      Tackle.Lib.last_answer(state)
  """

  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.State

  @doc """
  Creates a new agent state. See `Tackle.Lib.State.new/1` for options.
  """
  defdelegate new(opts \\ []), to: State

  @doc """
  Runs the agent for a user query.

  ## Options
    * `:event_callback` - Function called with `%Tackle.Lib.Event{}` structs.
    * `:llm_stream` - When true, use `Tackle.Lib.LLM.stream/4` if configured adapter supports it.
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
  @spec usage(State.t()) :: Tackle.Lib.Usage.t()
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
