defmodule Tackle.Config.Watchdog do
  @moduledoc """
  Configuration for the per-session command watchdog (`Tackle.Watchdog`).

  The watchdog is opt-in: it needs a local decision model, so `new/2` returns
  `{:ok, nil}` for `nil`, `false`, or `enabled: false`. When enabled:

    * `:model` (required) - canonical decision model reference, such as
      `"ollama/tev1:4b"`, resolved eagerly through `Tackle.Lib.Decision.select/2`
      against the session's providers so an unknown model fails configuration.
    * `:after_seconds` - how long a `bash` command runs before its first check
      (default 60), a positive number of seconds up to 4,294,967.295, the
      longest Erlang timer (`2^32 - 1` milliseconds). Later checks back off
      while the command looks healthy.
    * `:threshold` - minimum probability, in `(0, 1]`, of a stop verdict
      (`waiting_for_input`, `infinite_loop`, or `stalled`) before the command
      is stopped (default 0.85).

  In `config.json`:

      "watchdog": {"model": "ollama/tev1:4b", "after_seconds": 60, "threshold": 0.85}
  """

  alias Tackle.Config.Options
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

  @option_keys [:model, :after_seconds, :threshold]

  @doc """
  Builds and validates a watchdog config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers); the decision model
  is resolved against them.
  """
  @spec new(keyword() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(value, providers),
    do: Options.new(value, :watchdog, @option_keys, &build(&1, providers))

  @doc "Returns the delay before a command's first check, in milliseconds."
  @spec after_ms(t()) :: pos_integer()
  def after_ms(%__MODULE__{after_seconds: seconds}), do: Options.to_ms(seconds)

  defp build(opts, providers) do
    with {:ok, model_ref} <- Options.fetch_model(opts, :watchdog),
         {:ok, after_seconds} <-
           Options.fetch_seconds(opts, :watchdog, :after_seconds, @default_after_seconds),
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

  defp fetch_threshold(opts) do
    case Keyword.get(opts, :threshold, @default_threshold) do
      threshold when is_number(threshold) and threshold > 0 and threshold <= 1 -> {:ok, threshold}
      threshold -> Options.invalid(:watchdog, threshold: threshold)
    end
  end
end
