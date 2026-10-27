defmodule Tackle.Config.SessionTitles do
  @moduledoc """
  Configuration for LLM-generated session titles.

  A config value is present only when generation is enabled: `new/2` returns
  `{:ok, nil}` for `nil`, `false`, or `enabled: false`. `:model` is a canonical
  model reference such as `"openai-codex/gpt-5.5"` used for the
  title-generation call; when absent or `nil`, the session's configured model is
  used.

  The reference is resolved against the session's providers eagerly so an
  unknown model fails configuration instead of the first turn. `Tackle.Config.new/1`
  treats an absent option as disabled; the harness loader (`Tackle.Config.load/1`)
  enables titles by default so explicit configuration can opt out.
  """

  alias Tackle.Config.Options
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection

  defstruct [:model_ref, :selection]

  @type t :: %__MODULE__{
          model_ref: String.t() | nil,
          selection: Selection.t() | nil
        }

  @option_keys [:model]

  @doc """
  Builds and validates a session-titles config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers), used to resolve an
  explicit `:model` reference into a selection.
  """
  @spec new(keyword() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(value, providers),
    do: Options.new(value, :session_titles, @option_keys, &build(&1, providers))

  defp build(opts, providers) do
    if Keyword.get(opts, :model) == nil do
      {:ok, %__MODULE__{}}
    else
      with {:ok, model_ref} <- Options.fetch_model(opts, :session_titles),
           {:ok, selection} <- LLM.select(providers, model_ref) do
        {:ok, %__MODULE__{model_ref: model_ref, selection: selection}}
      end
    end
  end
end
