defmodule Tackle.Config.SessionTitles do
  @moduledoc """
  Configuration for LLM-generated session titles.

  A config value is present only when generation is enabled: `new/2` returns
  `{:ok, nil}` for `nil`, `false`, or `enabled: false`. `:model` is a canonical
  model reference such as `"openai-codex/gpt-5.5"` used for the
  title-generation call; when absent, the session's configured model is used.

  The reference is resolved against the session's providers eagerly so an
  unknown model fails configuration instead of the first turn. `Tackle.Config.new/1`
  treats an absent option as disabled; the harness loader (`Tackle.Config.load/1`)
  enables titles by default so explicit configuration can opt out.
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection

  defstruct [:model_ref, :selection]

  @type t :: %__MODULE__{
          model_ref: String.t() | nil,
          selection: Selection.t() | nil
        }

  @option_keys [:enabled, :model]

  @doc """
  Builds and validates a session-titles config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers), used to resolve an
  explicit `:model` reference into a selection.
  """
  @spec new(keyword() | t() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(nil, _providers), do: {:ok, nil}
  def new(false, _providers), do: {:ok, nil}

  def new(%__MODULE__{} = config, providers),
    do: config |> config_options() |> new(providers)

  def new(opts, providers) when is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_enabled(opts),
         {:ok, model_ref} <- fetch_model_ref(opts),
         {:ok, selection} <- resolve_selection(model_ref, providers) do
      if Keyword.get(opts, :enabled, true) do
        {:ok, %__MODULE__{model_ref: model_ref, selection: selection}}
      else
        {:ok, nil}
      end
    end
  end

  def new(other, _providers), do: {:error, {:invalid_option, :session_titles, other}}

  defp config_options(%__MODULE__{model_ref: model_ref}), do: [model: model_ref]

  defp validate_options(opts) do
    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_option, :session_titles, Enum.uniq(unknown)}}
    end
  end

  defp validate_enabled(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, enabled} when is_boolean(enabled) -> :ok
      {:ok, enabled} -> {:error, {:invalid_option, :session_titles, enabled: enabled}}
      :error -> :ok
    end
  end

  defp fetch_model_ref(opts) do
    case Keyword.get(opts, :model) do
      nil -> {:ok, nil}
      model_ref when is_binary(model_ref) and model_ref != "" -> {:ok, model_ref}
      model_ref -> {:error, {:invalid_option, :session_titles, model: model_ref}}
    end
  end

  defp resolve_selection(nil, _providers), do: {:ok, nil}

  defp resolve_selection(model_ref, providers), do: LLM.select(providers, model_ref)
end
