defmodule Tackle.Config.Narration do
  @moduledoc """
  Configuration for the narrator (`Tackle.Narrator`), which writes a short live
  status line for each running subagent and workflow child.

  Narration is opt-in: it needs a small, ideally local, chat model, so `new/2`
  returns `{:ok, nil}` for `nil`, `false`, or `enabled: false`. When enabled:

    * `:model` (required) - canonical chat model reference, such as
      `"ollama/gemma4:12b"`, resolved eagerly through `Tackle.Lib.LLM.select/2`
      against the session's providers so an unknown model fails configuration.
      There is no fallback to the session model, which may be a paid remote
      one.
    * `:interval_seconds` - minimum time between two narrations of the same
      run (default 5).
    * `:first_after_seconds` - how long a run works before its first
      narration (default 5), so short runs are never narrated.

  In `config.json`:

      "narration": {"model": "ollama/gemma4:12b", "interval_seconds": 5,
                    "first_after_seconds": 5}
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection

  @default_interval_seconds 5
  @default_first_after_seconds 5

  @enforce_keys [:model_ref, :selection]
  defstruct [
    :model_ref,
    :selection,
    interval_seconds: @default_interval_seconds,
    first_after_seconds: @default_first_after_seconds
  ]

  @type t :: %__MODULE__{
          model_ref: String.t(),
          selection: Selection.t(),
          interval_seconds: number(),
          first_after_seconds: number()
        }

  @option_keys [:enabled, :model, :interval_seconds, :first_after_seconds]

  @doc """
  Builds and validates a narration config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers); the chat model is
  resolved against them.
  """
  @spec new(keyword() | t() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(nil, _providers), do: {:ok, nil}
  def new(false, _providers), do: {:ok, nil}

  def new(%__MODULE__{} = config, providers) do
    new(
      [
        model: config.model_ref,
        interval_seconds: config.interval_seconds,
        first_after_seconds: config.first_after_seconds
      ],
      providers
    )
  end

  def new(opts, providers) when is_list(opts) do
    with :ok <- validate_keys(opts),
         {:ok, enabled} <- fetch_enabled(opts) do
      if enabled, do: build(opts, providers), else: {:ok, nil}
    end
  end

  def new(other, _providers), do: invalid(other)

  @doc "Minimum time between two narrations of one run, in milliseconds."
  @spec interval_ms(t()) :: pos_integer()
  def interval_ms(%__MODULE__{interval_seconds: seconds}), do: to_ms(seconds)

  @doc "How long a run works before its first narration, in milliseconds."
  @spec first_after_ms(t()) :: pos_integer()
  def first_after_ms(%__MODULE__{first_after_seconds: seconds}), do: to_ms(seconds)

  defp to_ms(seconds), do: max(round(seconds * 1_000), 1)

  defp build(opts, providers) do
    with {:ok, model_ref} <- fetch_model(opts),
         {:ok, interval} <- fetch_seconds(opts, :interval_seconds, @default_interval_seconds),
         {:ok, first_after} <-
           fetch_seconds(opts, :first_after_seconds, @default_first_after_seconds),
         {:ok, selection} <- LLM.select(providers, model_ref) do
      {:ok,
       %__MODULE__{
         model_ref: model_ref,
         selection: selection,
         interval_seconds: interval,
         first_after_seconds: first_after
       }}
    end
  end

  defp validate_keys(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- @option_keys do
        [] -> :ok
        unknown -> invalid(Enum.uniq(unknown))
      end
    else
      invalid(opts)
    end
  end

  defp fetch_enabled(opts) do
    case Keyword.get(opts, :enabled, true) do
      enabled when is_boolean(enabled) -> {:ok, enabled}
      enabled -> invalid(enabled: enabled)
    end
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      model -> invalid(model: model)
    end
  end

  defp fetch_seconds(opts, key, default) do
    case Keyword.get(opts, key, default) do
      seconds when is_number(seconds) and seconds > 0 -> {:ok, seconds}
      seconds -> invalid([{key, seconds}])
    end
  end

  defp invalid(detail), do: {:error, {:invalid_option, :narration, detail}}
end
