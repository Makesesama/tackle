defmodule Tackle.Web.Agent do
  @moduledoc """
  The review assistant: which providers it can run, and the agent state for one
  conversation.

  This is the host facade `Tackle.Phoenix.Runner` expects under its `:agent`
  config key. It builds a `Tackle.Lib.State` for one review conversation and
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
  conversation's `:cwd` — the review's own checkout, whether that is a pull
  request clone or a local repository. `bash` is what makes
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
  alias Tackle.Web.Providers

  @tools [Read, Bash]

  # Enough for a few rounds of reading and grepping. The loop stops here rather
  # than running away on a question the checkout cannot answer.
  @max_iterations 30

  @typedoc "A review, as much as the assistant needs to reason about it."
  @type review :: %{
          review_id: String.t(),
          title: String.t() | nil,
          base_ref: String.t() | nil,
          head_ref: String.t() | nil
        }

  @doc """
  The provider adapters this host offers.

  Resolved by `Tackle.Web.Providers`, which the chat frontend uses too, so both
  surfaces offer the same providers and honour the same override.
  """
  @spec adapters() :: [module()]
  def adapters, do: Providers.adapters()

  @doc "The tools the assistant may call."
  @spec tools() :: [module()]
  def tools, do: @tools

  @doc "Every `adapter/model` reference the assistant can run."
  @spec models() :: [String.t()]
  def models, do: Providers.models()

  @doc """
  The model used when a conversation does not pick one.

  Configured with `config :tackle_web, :agent_model`, falling back to the first
  model the adapters list.
  """
  @spec default_model() :: String.t() | nil
  def default_model, do: Providers.default_model()

  @doc """
  Resolves a canonical `adapter/model` reference against the available adapters.

  `nil` selects `default_model/0`.
  """
  @spec select(String.t() | nil) :: {:ok, LLM.Selection.t()} | {:error, term()}
  def select(model_ref), do: Providers.select(model_ref)

  @doc """
  The credential-store handle handed to adapters.

  Non-secret: it names the host's store and the reference to look up in it.
  """
  @spec credential_store() :: Tackle.Lib.CredentialStore.handle()
  def credential_store, do: Tackle.Auth.credential_store()

  @doc """
  Builds the agent state for one review conversation.

  Takes a loaded review as `Tackle.Web.Projects.load_review/2` returns it, so the
  prompt, the context and the working directory all describe the same review.

  ## Options

    * `:model` — a canonical `adapter/model` reference; defaults to
      `default_model/0`.
    * `:messages` — messages to restore a previous conversation from.
  """
  @spec new(Tackle.Web.Project.Source.loaded_review(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def new(loaded, opts \\ []) do
    with {:ok, selection} <- select(Keyword.get(opts, :model)) do
      {:ok, build(selection, loaded, opts)}
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

  defp build(selection, loaded, opts) do
    tools = tools()

    state =
      State.new(
        llm: selection,
        tools: tools,
        context: context(loaded),
        system_prompt: system_prompt(tools, loaded),
        # Where the adapters find the host's credential store.
        llm_opts: [credential_store: credential_store()],
        max_iterations: @max_iterations
      )

    Enum.reduce(Keyword.get(opts, :messages, []), state, &State.add_message(&2, &1))
  end

  defp context(loaded) do
    %{
      cwd: loaded.cwd,
      project: loaded.project,
      review: %{
        review_id: loaded.review_id,
        title: loaded.title,
        base_ref: loaded.base_ref,
        head_ref: loaded.head_ref
      }
    }
  end

  defp system_prompt(tools, loaded) do
    SystemPrompt.new()
    |> SystemPrompt.add_section("Your job", job())
    |> SystemPrompt.add_section("The review", facts(loaded))
    |> SystemPrompt.add_section("How to work", how_to_work())
    |> SystemPrompt.add_tools(tools)
    |> SystemPrompt.add_response_format()
    |> SystemPrompt.to_string()
  end

  defp job do
    """
    You are helping a reviewer understand one diff. The reviewer reads it and
    asks you questions about it, and your answers are shown beside the code they
    are looking at.

    Answer the question that was asked. A reviewer asking about one line usually
    wants to know whether it is correct, what it affects, or why it is there --
    not a summary of the diff.
    """
  end

  defp facts(loaded) do
    """
    - Project: #{loaded.project.name} (#{loaded.project.kind}, #{loaded.project.locator})
    - Review: #{loaded.review_id}#{title_suffix(loaded)}
    - Comparing: #{loaded.base_ref || "unknown"} <- #{loaded.head_ref || "unknown"}
    - Checkout: #{loaded.cwd}
    #{checkout_note(loaded)}
    The diff under review is `git diff $(git merge-base #{loaded.base_ref || "HEAD"} #{head_revision(loaded)}) #{head_revision(loaded)}`.
    """
  end

  # On GitHub the checkout is a working copy at the review's head, so `HEAD` is
  # the revision under review. A local project's checkout is the repository
  # itself, which is probably on another branch, so the head ref has to be named.
  defp checkout_note(%{project: %{kind: :github}}),
    do: "  It has the review's head commit checked out, so relative paths resolve from there.\n"

  defp checkout_note(_loaded),
    do:
      "  This is the repository itself and may be on another branch: read the reviewed revision with git, for example `git show REV:path`.\n"

  defp head_revision(%{project: %{kind: :github}}), do: "HEAD"
  defp head_revision(loaded), do: loaded.head_ref || "HEAD"

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
  defp title_suffix(_loaded), do: ""
end
