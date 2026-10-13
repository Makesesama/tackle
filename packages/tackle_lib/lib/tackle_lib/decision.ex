defmodule Tackle.Lib.Decision do
  @moduledoc """
  Optional provider-neutral contract for small, local decision models.

  A decision model does not chat: it answers a fixed set of typed questions
  (`Tackle.Lib.Decision.Question`) about one observed state and reports
  probabilities. Hosts use it for cheap judgements such as "is this command
  stuck?" without spending a full LLM turn.

  Adapters may implement this behaviour in addition to `Tackle.Lib.LLM`. They
  must also export `adapter_id/0`. Decision model references are prefixed by a
  provider id just like chat model references (see `Tackle.Lib.LLM.Provider`):

      {:ok, selection} = Tackle.Lib.Decision.select(adapters, "ollama/tev1:4b")

      question =
        Tackle.Lib.Decision.Question.choice("verdict", "Is the command stuck?", %{
          "progressing" => "Output is still advancing",
          "stalled" => nil
        })

      {:ok, %Tackle.Lib.Decision.Result{answers: %{"verdict" => answer}}} =
        Tackle.Lib.Decision.decide(selection, "command: make test ...", [question], [])

  This module is a pure contract: it validates requests and selections and
  normalizes results, while transport stays inside adapters.

  ## Local adapters

  An adapter whose decision models run on hardware the user controls, such as
  a self-hosted Ollama server, may export the optional `local?/1` (per provider
  settings) or `local?/0` callback returning `true`. Its selections carry
  `local: true`, so a host can leave their usage out of token budgets that
  bound paid spend. Adapters that export neither are treated as remote.

  ## Options

  `decide/3` passes its options to the adapter's `decide/2`, adding the
  selection's `:provider_id` and `:provider_settings`. Adapters should honour:

    * `:cancellation_signal` - a `Tackle.Lib.Cancellation.Signal`; abort the
      request and return `{:error, :cancelled}` when it is cancelled.
    * `:receive_timeout` - maximum milliseconds to wait for a response.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Decision.{Question, Request, Result, Selection}
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Usage

  @doc "The adapter-local decision model identifiers available for selection."
  @callback decision_models() :: [String.t()]

  @doc "Like `decision_models/0`, for one provider's settings. Preferred when exported."
  @callback decision_models(settings :: Provider.settings()) :: [String.t()]

  @doc """
  Answers every question of an already validated request.

  `request.model` is the adapter-local decision model id. Return a result whose
  `answers` are keyed by question name, or `{:error, reason}`.
  """
  @callback decide(Request.t(), opts :: keyword()) :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Whether the adapter's decision models run locally, on hardware the user
  controls, so their usage is not paid per token. Defaults to `false` when not
  exported.
  """
  @callback local?() :: boolean()

  @doc "Like `local?/0`, for one provider's settings. Preferred when exported."
  @callback local?(settings :: Provider.settings()) :: boolean()

  @optional_callbacks decision_models: 0, decision_models: 1, local?: 0, local?: 1

  @doc """
  Selects a decision provider and model from a canonical `provider_id/model` reference.

  Sources and references are handled like `Tackle.Lib.LLM.select/2`. Every
  adapter must export `adapter_id/0` and provider ids must be unique; providers
  without decision support may be listed, but selecting one returns
  `{:error, {:unsupported_decision_adapter, provider_id}}`. A model missing from
  the decision models returns `{:error, {:unknown_decision_model, ref}}`. The
  selection's `local` flag comes from the optional `local?/1` or `local?/0`; a
  non-boolean answer returns `{:error, {:invalid_local_flag, provider_id, value}}`.
  """
  @spec select([Provider.source()], String.t()) :: {:ok, Selection.t()} | {:error, term()}
  defdelegate select(adapters, model_ref), to: Selection, as: :resolve

  @doc """
  Validates a request and asks the selected adapter to answer it.

  The selection's model replaces `request.model`. A cancelled
  `:cancellation_signal` returns `{:error, :cancelled}` without calling the
  adapter. Result usage is normalized into `Tackle.Lib.Usage`.
  """
  @spec decide(Selection.t(), Request.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def decide(%Selection{} = selection, %Request{} = request, opts \\ []) when is_list(opts) do
    request = %{request | model: selection.model}

    opts =
      opts
      |> Keyword.put(:provider_id, selection.provider_id)
      |> Keyword.put(:provider_settings, selection.provider_settings)

    with :ok <- Request.validate(request),
         :ok <- ensure_not_cancelled(opts) do
      request
      |> selection.adapter.decide(opts)
      |> normalize_result(selection)
    end
  end

  @doc """
  Builds the request from `state` and `questions`, then calls `decide/3`.
  """
  @spec decide(Selection.t(), Request.state(), [Question.t()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def decide(%Selection{} = selection, state, questions, opts)
      when is_list(questions) and is_list(opts),
      do: decide(selection, Request.new(state, questions), opts)

  defp ensure_not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp normalize_result({:ok, %Result{} = result}, %Selection{} = selection) do
    model = result.model || selection.model
    usage = Usage.normalize(result.usage, model: model, provider: selection.provider_id)
    {:ok, %{result | model: model, usage: usage}}
  end

  defp normalize_result({:error, reason}, _selection), do: {:error, reason}

  defp normalize_result(other, %Selection{adapter: adapter}),
    do: {:error, {:invalid_decision_result, adapter, other}}
end
