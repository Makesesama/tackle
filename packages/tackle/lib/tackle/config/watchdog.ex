defmodule Tackle.Config.Watchdog do
  @moduledoc """
  Configuration for the per-session command watchdog (`Tackle.Watchdog`).

  The watchdog is opt-in: it needs a local decision model, so `new/2` returns
  `{:ok, nil}` for `nil`, `false`, or `enabled: false`. When enabled:

    * `:model` (required) - canonical decision model reference, such as
      `"ollama/tev1:4b"`, resolved eagerly through `Tackle.Lib.Decision.select/2`
      against the session's providers so an unknown model fails configuration.
    * `:after_seconds` - how long a `bash` command runs before its first check
      (default 60). Later checks back off while the command looks healthy.
    * `:threshold` - minimum probability, in `(0, 1]`, of a stop verdict
      (`waiting_for_input`, `infinite_loop`, or `stalled`) before the command
      is stopped (default 0.85).

  In `config.json`:

      "watchdog": {"model": "ollama/tev1:4b", "after_seconds": 60, "threshold": 0.85}
  """

  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.Selection

  @default_after_seconds 60
  @default_threshold 0.85

  @enforce_keys [:model_ref, :selection]
  defstruct [
    :model_ref,
    :selection,
    after_seconds: @default_after_seconds,
    threshold: @default_threshold
  ]

  @type t :: %__MODULE__{
          model_ref: String.t(),
          selection: Selection.t(),
          after_seconds: number(),
          threshold: number()
        }

  @option_keys [:enabled, :model, :after_seconds, :threshold]

  @doc """
  Builds and validates a watchdog config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers); the decision model
  is resolved against them.
  """
  @spec new(keyword() | t() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(nil, _providers), do: {:ok, nil}
  def new(false, _providers), do: {:ok, nil}

  def new(%__MODULE__{} = config, providers) do
    new(
      [model: config.model_ref, after_seconds: config.after_seconds, threshold: config.threshold],
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

  @doc "Returns the delay before a command's first check, in milliseconds."
  @spec after_ms(t()) :: pos_integer()
  def after_ms(%__MODULE__{after_seconds: seconds}), do: max(round(seconds * 1_000), 1)

  defp build(opts, providers) do
    with {:ok, model_ref} <- fetch_model(opts),
         {:ok, after_seconds} <- fetch_after_seconds(opts),
         {:ok, threshold} <- fetch_threshold(opts),
         {:ok, selection} <- Decision.select(providers, model_ref) do
      {:ok,
       %__MODULE__{
         model_ref: model_ref,
         selection: selection,
         after_seconds: after_seconds,
         threshold: threshold
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

  defp fetch_after_seconds(opts) do
    case Keyword.get(opts, :after_seconds, @default_after_seconds) do
      seconds when is_number(seconds) and seconds > 0 -> {:ok, seconds}
      seconds -> invalid(after_seconds: seconds)
    end
  end

  defp fetch_threshold(opts) do
    case Keyword.get(opts, :threshold, @default_threshold) do
      threshold when is_number(threshold) and threshold > 0 and threshold <= 1 -> {:ok, threshold}
      threshold -> invalid(threshold: threshold)
    end
  end

  defp invalid(detail), do: {:error, {:invalid_option, :watchdog, detail}}
end
