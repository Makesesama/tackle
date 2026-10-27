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
        Tackle.Lib.Decision.ask(selection, "command: make test ...", [question])

  This module is the boundary between hosts and adapters, like
  `Tackle.Lib.LLM` for chat: it validates requests and selections, checks
  every result against the request's questions, and turns adapter crashes
  into errors, while transport stays inside adapters. Adapters need not
  repeat these checks.

  ## Local adapters

  An adapter whose decision models run on hardware the user controls, such as
  a self-hosted Ollama server, may export the optional `local?/1` (per provider
  settings) or `local?/0` callback returning `true`. Its selections carry
  `local: true`, so a host can leave their usage out of token budgets that
  bound paid spend. Adapters that export neither are treated as remote.

  ## Options

  `decide/3` (and `ask/4`) pass their options to the adapter's `decide/2`,
  adding the selection's `:provider_id` and `:provider_settings`. Adapters
  should honour:

    * `:cancellation_signal` - a `Tackle.Lib.Cancellation.Signal`; abort the
      request and return `{:error, :cancelled}` when it is cancelled.
    * `:receive_timeout` - maximum milliseconds to wait for a response.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Decision.{Question, Request, Result, Selection}
  alias Tackle.Lib.LLM.{Error, Provider}
  alias Tackle.Lib.Usage

  @doc "The adapter-local decision model identifiers available for selection."
  @callback decision_models() :: [String.t()]

  @doc "Like `decision_models/0`, for one provider's settings. Preferred when exported."
  @callback decision_models(settings :: Provider.settings()) :: [String.t()]

  @doc """
  Answers every question of an already validated request.

  `request.model` is the adapter-local decision model id, already checked
  against the provider's decision models. Return a result with one answer per
  question, keyed by question name, or `{:error, reason}`; provider and
  transport failures should be `Tackle.Lib.LLM.Error`s. `decide/3` checks the
  result (see `Tackle.Lib.Decision.Result.validate/2`).
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
  Whether `adapter` implements this contract: it can be loaded and exports
  `decide/2` and `decision_models/1` or `decision_models/0`.

  `select/2` selects only from such adapters; hosts use it to find the
  providers that offer decision models.
  """
  @spec decision_adapter?(module()) :: boolean()
  def decision_adapter?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :decide, 2) and
      (function_exported?(adapter, :decision_models, 1) or
         function_exported?(adapter, :decision_models, 0))
  end

  def decision_adapter?(_adapter), do: false

  @doc """
  Validates a request and asks the selected adapter to answer it.

  The selection's model replaces `request.model`. A request that fails
  `Tackle.Lib.Decision.Request.validate/1` returns its
  `{:invalid_decision_request, detail}` error, and a cancelled
  `:cancellation_signal` returns `{:error, :cancelled}`, both without calling
  the adapter. Adapter errors are returned as they are.

  Like `Tackle.Lib.LLM.generate_with/3`, the call never raises:

    * an adapter that raises, throws, or exits returns
      `{:error, %Tackle.Lib.LLM.Error{kind: :unknown}}`, whose `details` hold
      the `:adapter`, `:kind`, `:reason`, and `:stacktrace`;
    * a result that does not answer the request
      (`Tackle.Lib.Decision.Result.validate/2`), and any return other than
      `{:ok, %Tackle.Lib.Decision.Result{}}` or `{:error, reason}`, returns
      `{:error, %Tackle.Lib.LLM.Error{kind: :invalid_response}}`, whose
      `details` hold the `:reason` and the result's normalized `:usage` (the
      model still spent the tokens).

  A successful result answers exactly the request's questions. Its `model`
  defaults to the selection's model, and its usage is normalized into
  `Tackle.Lib.Usage`.
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
      selection
      |> invoke(request, opts)
      |> check_result(request, selection)
    end
  end

  @doc """
  Builds a request from `state` and `questions`, then calls `decide/3`.
  """
  @spec ask(Selection.t(), Request.state(), [Question.t()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def ask(%Selection{} = selection, state, questions, opts \\ [])
      when is_list(questions) and is_list(opts),
      do: decide(selection, Request.new(state, questions), opts)

  defp ensure_not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  # Calls the adapter. Anything other than `{:ok, result}` or
  # `{:error, reason}`, and any exception, throw, or exit, becomes an error.
  defp invoke(%Selection{adapter: adapter}, request, opts) do
    case adapter.decide(request, opts) do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:invalid, {:result, other}}
    end
  rescue
    exception -> {:error, adapter_failure(adapter, :error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, adapter_failure(adapter, kind, reason, __STACKTRACE__)}
  end

  defp adapter_failure(adapter, kind, reason, stacktrace) do
    Error.new(:unknown,
      message: "The decision adapter #{inspect(adapter)} failed: #{failure_text(kind, reason)}",
      details: %{adapter: adapter, kind: kind, reason: reason, stacktrace: stacktrace}
    )
  end

  defp failure_text(:error, exception), do: Exception.message(exception)

  defp failure_text(kind, reason),
    do: "#{kind} #{inspect(reason, limit: 10, printable_limit: 200)}"

  defp check_result({:ok, %Result{} = result}, request, selection) do
    case Result.validate(result, request.questions) do
      :ok ->
        model = result.model || selection.model
        {:ok, %{result | model: model, usage: usage(result.usage, model, selection)}}

      {:error, detail} ->
        {:error, invalid_response(detail, result, selection)}
    end
  end

  defp check_result({:ok, _other} = other, _request, selection),
    do: {:error, invalid_response({:result, other}, nil, selection)}

  defp check_result({:invalid, detail}, _request, selection),
    do: {:error, invalid_response(detail, nil, selection)}

  defp check_result({:error, _reason} = error, _request, _selection), do: error

  # An unusable result keeps its usage, when it has a usable one, in the
  # details: the model still spent the tokens.
  defp invalid_response(detail, result, selection) do
    usage =
      case result do
        %Result{usage: usage, model: model} when is_map(usage) ->
          usage(usage, if(is_binary(model), do: model, else: selection.model), selection)

        _other ->
          nil
      end

    Error.new(:invalid_response,
      message: "Invalid decision response: #{inspect(detail, limit: 10, printable_limit: 200)}",
      details: %{reason: detail, usage: usage}
    )
  end

  defp usage(usage, model, %Selection{provider_id: provider_id}),
    do: Usage.normalize(usage, model: model, provider: provider_id)
end
