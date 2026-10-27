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

  Both are positive numbers of seconds up to 4,294,967.295, the longest
  Erlang timer (`2^32 - 1` milliseconds).

  In `config.json`:

      "narration": {"model": "ollama/gemma4:12b", "interval_seconds": 5,
                    "first_after_seconds": 5}
  """

  alias Tackle.Config.Options
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

  @option_keys [:model, :interval_seconds, :first_after_seconds]

  @doc """
  Builds and validates a narration config from options.

  `providers` are the session's providers (`Tackle.Lib.LLM.Provider` structs or
  adapter modules standing for their default providers); the chat model is
  resolved against them.
  """
  @spec new(keyword() | false | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(value, providers),
    do: Options.new(value, :narration, @option_keys, &build(&1, providers))

  @doc "Minimum time between two narrations of one run, in milliseconds."
  @spec interval_ms(t()) :: pos_integer()
  def interval_ms(%__MODULE__{interval_seconds: seconds}), do: Options.to_ms(seconds)

  @doc "How long a run works before its first narration, in milliseconds."
  @spec first_after_ms(t()) :: pos_integer()
  def first_after_ms(%__MODULE__{first_after_seconds: seconds}), do: Options.to_ms(seconds)

  defp build(opts, providers) do
    with {:ok, model_ref} <- Options.fetch_model(opts, :narration),
         {:ok, interval} <-
           Options.fetch_seconds(
             opts,
             :narration,
             :interval_seconds,
             @default_interval_seconds
           ),
         {:ok, first_after} <-
           Options.fetch_seconds(
             opts,
             :narration,
             :first_after_seconds,
             @default_first_after_seconds
           ),
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
end
