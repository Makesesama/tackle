defmodule Tackle.Workflow.Decisions do
  @moduledoc """
  The decision models a host grants to a workflow's `tackle.classify`.

  A host passes this grant as `Tackle.Workflow.run/3`'s `:decisions` option, or
  `Tackle.Workflow.Tool` reads it from the session context under `:decisions`.
  It is trusted host configuration, never workflow input:

    * `:adapters` (required) — executable adapter modules. A script can only
      select a decision model one of them already offers through
      `Tackle.Lib.Decision.select/2`; adapters without decision support may be
      listed and are ignored.
    * `:options` — keyword options passed to every
      `Tackle.Lib.Decision.decide/3` call, such as `:provider_options` and
      `:receive_timeout`. Defaults to `[]`.
    * `:default_model` — canonical decision model reference, such as
      `"ollama/tev1:4b"`, used when a script names no model. It is resolved
      eagerly, so an unknown default fails the grant. Defaults to `nil`: scripts
      must then name a model.

  A selection whose adapter declares its decision models local
  (`Tackle.Lib.Decision.local?/0`) spends no budgeted tokens; every other
  classification's tokens count against the workflow's token budget.
  """

  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.{Request, Result, Selection}

  defstruct adapters: [], options: [], default_model: nil

  @type t :: %__MODULE__{
          adapters: [module()],
          options: keyword(),
          default_model: String.t() | nil
        }

  @keys [:adapters, :options, :default_model]
  @decision_callbacks [adapter_id: 0, decision_models: 0, decide: 2]

  @doc """
  Builds and validates a grant from a map, keyword list, or struct. `nil`
  grants no decision models.

  Returns `{:error, {:invalid_workflow_option, :decisions, detail}}` for a
  malformed grant, or the `Tackle.Lib.Decision.select/2` error for an
  unknown default model.
  """
  @spec new(t() | map() | keyword() | nil) :: {:ok, t() | nil} | {:error, term()}
  def new(nil), do: {:ok, nil}
  def new(%__MODULE__{} = decisions), do: decisions |> Map.from_struct() |> new()

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: new(Map.new(opts)), else: invalid(opts)
  end

  def new(%{} = opts) do
    with :ok <- validate_keys(opts),
         {:ok, adapters} <- adapters(Map.get(opts, :adapters)),
         {:ok, options} <- options(Map.get(opts, :options, [])),
         {:ok, default_model} <- default_model(Map.get(opts, :default_model), adapters) do
      {:ok, %__MODULE__{adapters: adapters, options: options, default_model: default_model}}
    end
  end

  def new(other), do: invalid(other)

  @doc """
  Selects the decision model for one classification: `model_ref` when given,
  otherwise the grant's default.

  Returns `{:error, :no_model}` when neither names a model.
  """
  @spec select(t(), String.t() | nil) :: {:ok, Selection.t()} | {:error, term()}
  def select(%__MODULE__{default_model: nil}, nil), do: {:error, :no_model}

  def select(%__MODULE__{default_model: default} = decisions, nil),
    do: select(decisions, default)

  def select(%__MODULE__{adapters: adapters}, model_ref) when is_binary(model_ref),
    do: Decision.select(adapters, model_ref)

  @doc """
  The canonical references of every decision model the grant offers, sorted.

  Adapters whose callbacks fail are skipped: the list only helps a script name
  a model, and selection reports their failure explicitly.
  """
  @spec available(t()) :: [String.t()]
  def available(%__MODULE__{adapters: adapters}) do
    adapters
    |> Enum.filter(&decision_adapter?/1)
    |> Enum.flat_map(&model_refs/1)
    |> Enum.sort()
  end

  @doc """
  Asks the selected model to answer `request` with the grant's options.

  An adapter that raises, throws, or exits returns
  `{:error, {:adapter_failed, detail}}` instead of failing the workflow. (A
  cancelled workflow kills its worker, which no adapter can intercept.)
  """
  @spec decide(t(), Selection.t(), Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def decide(%__MODULE__{options: options}, %Selection{} = selection, %Request{} = request) do
    Decision.decide(selection, request, options)
  rescue
    exception -> {:error, {:adapter_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:adapter_failed, {kind, reason}}}
  end

  defp decision_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?(@decision_callbacks, fn {name, arity} ->
        function_exported?(adapter, name, arity)
      end)
  end

  defp model_refs(adapter) do
    adapter_id = adapter.adapter_id()

    for model <- adapter.decision_models(), is_binary(model), do: adapter_id <> "/" <> model
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  defp validate_keys(opts) do
    case Map.keys(opts) -- @keys do
      [] -> :ok
      unknown -> invalid(unknown: unknown)
    end
  end

  defp adapters(adapters) when is_list(adapters) do
    if Enum.all?(adapters, &is_atom/1), do: {:ok, adapters}, else: invalid(adapters: adapters)
  end

  defp adapters(adapters), do: invalid(adapters: adapters)

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options), do: {:ok, options}, else: invalid(options: options)
  end

  defp options(options), do: invalid(options: options)

  defp default_model(nil, _adapters), do: {:ok, nil}

  defp default_model(model_ref, adapters) when is_binary(model_ref) and model_ref != "" do
    with {:ok, _selection} <- Decision.select(adapters, model_ref), do: {:ok, model_ref}
  end

  defp default_model(model_ref, _adapters), do: invalid(default_model: model_ref)

  defp invalid(detail), do: {:error, {:invalid_workflow_option, :decisions, detail}}
end
