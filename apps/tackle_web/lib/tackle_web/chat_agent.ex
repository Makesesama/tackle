defmodule Tackle.Web.ChatAgent do
  @moduledoc """
  The ordinary Tackle agent, as the chat frontend asks for it.

  This is the host facade `Tackle.Phoenix.Runner` expects under its `:agent`
  config key. Where `Tackle.Web.Agent` composes a review-specific prompt and
  tool set, this module builds what the CLI builds for a normal session:
  `Tackle.Config.load/1` resolves the same validated configuration (tools,
  prompt, model, thinking level, provider credentials) from the same files and
  environment, and `Tackle.Config.to_agent_state/2` turns it into the
  `Tackle.Lib.State` the loop runs.

  The consequence is that a chat here behaves like `tackle` on the command line:
  it gets the built-in `read`, `bash`, `edit` and `write` tools, the system
  prompt assembled from `SYSTEM.md`, `AGENTS.md` and Agent Skills, and the
  credentials `mix tackle auth` stored. Nothing about the web frontend changes
  which tools exist or which providers can run.
  """

  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Web.Providers

  @doc """
  The directory a new conversation starts in.

  Configured with `config :tackle_web, :chat_cwd`, falling back to the directory
  the frontend was started from.
  """
  @spec default_cwd() :: Path.t()
  def default_cwd do
    case Application.get_env(:tackle_web, :chat_cwd) do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _unset -> File.cwd!()
    end
  end

  @doc "Every `adapter/model` reference a conversation can run."
  @spec models() :: [String.t()]
  def models, do: Providers.models()

  @doc "The model a conversation runs when the user does not pick one."
  @spec default_model() :: String.t() | nil
  def default_model, do: Providers.default_model()

  @doc """
  Builds the agent state for one conversation.

  ## Options

    * `:cwd` (required) — the directory the assistant reads and writes, and
      what `.`, `AGENTS.md` and the prompt's working-directory line resolve
      against.
    * `:model` — a canonical `adapter/model` reference; `nil` selects
      `default_model/0`.
    * `:messages` — a stored transcript to resume from.

  Returns `{:error, reason}` when the configuration cannot be resolved: an
  unknown model reference, a directory that is gone, or no provider adapters at
  all. The chat renders that instead of starting a turn that cannot work.
  """
  @spec new(keyword()) :: {:ok, State.t()} | {:error, term()}
  def new(opts) do
    with {:ok, config} <- load(opts) do
      state = Config.to_agent_state(config, credential_store: Auth.credential_store())
      {:ok, with_messages(state, Keyword.get(opts, :messages, []))}
    end
  end

  @doc """
  Runs one turn of the loop.

  `Tackle.Phoenix.Runner` calls this with the enriched state and the run options
  that carry the event callback and the cancellation signal, so the answer
  streams into the page and stays cancellable.

  The harness pins concurrent tool execution (`Tackle.Config` builds the state
  that way), and the loop needs a `Task.Supervisor` to run a batch in. This host
  supplies the one the application already starts, so a turn's tools are
  supervised exactly like the turn itself.
  """
  @spec continue(State.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def continue(%State{} = state, opts) do
    opts =
      opts
      |> Keyword.put_new(:llm_stream, true)
      |> Keyword.put_new(:tool_supervisor, Tackle.Web.AgentTaskSupervisor)

    Tackle.Lib.continue(state, opts)
  end

  @doc """
  Installs a stored transcript on a freshly built state.

  Used when a Runner is recreated, and when the model changes: the
  configuration is rebuilt (tools, prompt and model may all differ) while the
  conversation itself is carried over unchanged.
  """
  @spec with_messages(State.t(), [Message.t()]) :: State.t()
  def with_messages(%State{} = state, messages) when is_list(messages) do
    Enum.reduce(messages, state, &State.add_message(&2, &1))
  end

  defp load(opts) do
    Config.load(
      cwd: Keyword.get(opts, :cwd, default_cwd()),
      available_adapters: Providers.adapters(),
      overrides: overrides(opts)
    )
  end

  defp overrides(opts) do
    [llm_stream: true]
    |> maybe_put(:model, Keyword.get(opts, :model) || Providers.default_model())
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
