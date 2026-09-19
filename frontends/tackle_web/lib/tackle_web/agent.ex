defmodule Tackle.Web.Agent do
  @moduledoc """
  The review assistant: which providers it can run, and the agent state for one
  conversation.

  This is the host facade `Tackle.Phoenix.Runner` expects under its `:agent`
  config key. It builds a `Tackle.Lib.State` for a pull request conversation and
  delegates each turn to `Tackle.Lib`.

  ## Providers

  The available providers are the repo's plugin packages, wired exactly as any
  external plugin would be: both implement `Tackle.Lib.LLM`, and the model
  reference decides which one runs.

    * `Tackle.Plugins.Codex` (`openai-codex/*`) authenticates with a ChatGPT
      OAuth session, and resends a request when the provider rejects an expired
      token.
    * `Tackle.Plugins.DeepSeek` (`deepseek/*`) authenticates with an API key.

  Credentials come from `Tackle.Auth`, the harness's file-backed credential
  store, so a login performed by the CLI is reused here. The store handle is
  passed to adapters through `llm_opts`, which is where adapters look for it.

  ## Tools

  The assistant gets `read` and `bash`, both resolving paths against the
  conversation's `:cwd` — the pull request's own checkout. `bash` is what makes
  questions like "when did this change?" answerable at all: it is how the
  assistant runs `git log`, `git blame` and `rg`. It also means the assistant
  runs commands as the server user, inside that checkout. Treat a conversation
  as equivalent to shell access for whoever can open the page; a hosted
  deployment needs its own sandbox around this.
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.State
  alias Tackle.Lib.SystemPrompt
  alias Tackle.Tools.Bash
  alias Tackle.Tools.Read

  @default_adapters [Tackle.Plugins.Codex, Tackle.Plugins.DeepSeek]
  @tools [Read, Bash]

  # Enough for a few rounds of reading and grepping. The loop stops here rather
  # than running away on a question the checkout cannot answer.
  @max_iterations 30

  @typedoc "A pull request, as much as the assistant needs to reason about it."
  @type review :: %{
          owner: String.t(),
          repo: String.t(),
          number: pos_integer(),
          title: String.t() | nil,
          base_ref: String.t() | nil,
          head_ref: String.t() | nil
        }

  @doc """
  The provider adapters this host offers.

  Overridable with `config :tackle_web, :agent_adapters`, which is how a
  deployment adds a provider plugin of its own, and how tests run the assistant
  against a deterministic adapter instead of a real provider.
  """
  @spec adapters() :: [module()]
  def adapters do
    case Application.get_env(:tackle_web, :agent_adapters) do
      adapters when is_list(adapters) and adapters != [] -> adapters
      _unset -> @default_adapters
    end
  end

  @doc "The tools the assistant may call."
  @spec tools() :: [module()]
  def tools, do: @tools

  @doc "Every `adapter/model` reference the assistant can run."
  @spec models() :: [String.t()]
  def models do
    Enum.flat_map(adapters(), fn adapter ->
      adapter_id = adapter.adapter_id()
      Enum.map(adapter.models(), &"#{adapter_id}/#{&1}")
    end)
  end

  @doc """
  The model used when a conversation does not pick one.

  Configured with `config :tackle_web, :agent_model`, falling back to the first
  model the adapters list.
  """
  @spec default_model() :: String.t() | nil
  def default_model do
    case Application.get_env(:tackle_web, :agent_model) do
      model when is_binary(model) and model != "" -> model
      _unset -> List.first(models())
    end
  end

  @doc """
  Resolves a canonical `adapter/model` reference against the available adapters.

  `nil` selects `default_model/0`.
  """
  @spec select(String.t() | nil) :: {:ok, LLM.Selection.t()} | {:error, term()}
  def select(nil), do: select(default_model())
  def select(model_ref) when is_binary(model_ref), do: LLM.select(adapters(), model_ref)

  @doc """
  The credential-store handle handed to adapters.

  Non-secret: it names the host's store and the reference to look up in it.
  """
  @spec credential_store() :: Tackle.Lib.CredentialStore.handle()
  def credential_store, do: Tackle.Auth.credential_store()

  @doc """
  Builds the agent state for one review conversation.

  ## Options

    * `:cwd` (required) — the pull request checkout the assistant reads.
    * `:review` (required) — the `t:review/0` map the prompt describes.
    * `:model` — a canonical `adapter/model` reference; defaults to
      `default_model/0`.
    * `:messages` — messages to restore a previous conversation from.
  """
  @spec new(keyword()) :: {:ok, State.t()} | {:error, term()}
  def new(opts) do
    with {:ok, selection} <- select(Keyword.get(opts, :model)) do
      {:ok, build(selection, opts)}
    end
  end

  @doc """
  Runs one turn of the loop.

  `Tackle.Phoenix.Runner` calls this with the enriched state and the run options
  that carry the event callback and the cancellation signal, so the assistant
  streams and stays cancellable.
  """
  @spec continue(State.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def continue(%State{} = state, opts) do
    Tackle.Lib.continue(state, Keyword.put_new(opts, :llm_stream, true))
  end

  defp build(selection, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    review = Keyword.fetch!(opts, :review)
    tools = tools()

    state =
      State.new(
        llm: selection,
        tools: tools,
        context: %{cwd: cwd, review: review},
        system_prompt: system_prompt(tools, cwd, review),
        # Where the adapters find the host's credential store.
        llm_opts: [credential_store: credential_store()],
        max_iterations: @max_iterations
      )

    Enum.reduce(Keyword.get(opts, :messages, []), state, &State.add_message(&2, &1))
  end

  defp system_prompt(tools, cwd, review) do
    SystemPrompt.new()
    |> SystemPrompt.add_section("Your job", job())
    |> SystemPrompt.add_section("The pull request", facts(review, cwd))
    |> SystemPrompt.add_section("How to work", how_to_work())
    |> SystemPrompt.add_tools(tools)
    |> SystemPrompt.add_response_format()
    |> SystemPrompt.to_string()
  end

  defp job do
    """
    You are helping a reviewer understand one pull request. The reviewer reads
    the diff and asks you questions about it, and your answers are shown beside
    the code they are looking at.

    Answer the question that was asked. A reviewer asking about one line usually
    wants to know whether it is correct, what it affects, or why it is there --
    not a summary of the diff.
    """
  end

  defp facts(review, cwd) do
    """
    - Repository: #{review.owner}/#{review.repo}
    - Pull request: ##{review.number}#{title_suffix(review)}
    - Base branch: #{review.base_ref || "unknown"} <- Head: #{review.head_ref || "unknown"}
    - Checkout: #{cwd}, a full working copy with the pull request's head commit
      checked out. Relative paths resolve from there.

    The diff for this pull request is `git diff $(git merge-base #{review.base_ref || "HEAD"} HEAD) HEAD`.
    """
  end

  defp how_to_work do
    """
    Read the code before you describe it. Use the tools to open the files a
    question touches, and to search for callers, tests and related definitions.

    Ground every claim in something you actually read, and cite it as
    `path:line` so the reviewer can jump to it. When the code does not settle a
    question, say what you could not determine instead of guessing.

    Be concise and specific: a few sentences, or a short list. The reviewer is
    reading code, so refer to identifiers by name rather than restating them.
    """
  end

  defp title_suffix(%{title: title}) when is_binary(title) and title != "", do: " — #{title}"
  defp title_suffix(_review), do: ""
end
