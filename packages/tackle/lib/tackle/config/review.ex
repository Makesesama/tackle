defmodule Tackle.Config.Review do
  @moduledoc """
  Session defaults for code reviews (`Tackle.Review`).

    * `:thinking` - review stages (`:detector`, `:verifier`, `:scorer`) to
      thinking levels (`Tackle.Lib.Thinking.levels/0`);
    * `:models` - the same stages to canonical model references such as
      `"openai-codex/gpt-5.5"`, resolved against the session's providers;
    * `:profile` - which findings to show: `:quiet`, `:default`, or
      `:assertive` (`Tackle.Review.Rank`);
    * `:max_steps` - `:detector` and `:verifier` to step limits (model
      calls per run), replacing their profiles' `maxIterations`;
    * `:default_rules` - the ids of the built-in rules to apply
      (`Tackle.Review.Rules.builtin_ids/0`); `nil` applies all of them and
      `[]` none. User and project rules apply either way.

  `Tackle.Config.new/1` puts the settings in the session context under
  `:review_settings`, and `Tackle.Review.run/2` applies them to reviews
  requested from that session; its own options override them, per stage
  for the stage maps. Unset settings keep the review's defaults.

  In `config.json`:

      {
        "review": {
          "profile": "quiet",
          "models": { "verifier": "openai-codex/gpt-5.5-codex-mini" },
          "thinking": { "detector": "low", "verifier": "low" },
          "max_steps": { "verifier": 6 },
          "default_rules": ["unhandled-error", "injection", "secret-exposure"]
        }
      }
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.Thinking
  alias Tackle.Review.{Rank, Rules}

  defstruct thinking: %{}, models: %{}, profile: nil, max_steps: %{}, default_rules: nil

  @type stage :: :detector | :verifier | :scorer
  @type t :: %__MODULE__{
          thinking: %{optional(stage()) => String.t()},
          models: %{optional(stage()) => String.t()},
          profile: Rank.profile() | nil,
          max_steps: %{optional(:detector | :verifier) => pos_integer()},
          default_rules: [String.t()] | nil
        }

  @stages [:detector, :verifier, :scorer]
  @step_stages [:detector, :verifier]
  @option_keys [:thinking, :models, :profile, :max_steps, :default_rules]

  @doc "The review stages thinking levels and models may name."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "The review stages step limits may name."
  @spec step_stages() :: [:detector | :verifier]
  def step_stages, do: @step_stages

  @doc """
  Builds and validates review settings from options (see the module
  documentation); stage maps may be maps or keyword lists. `nil` means no
  settings. `providers` (as for `Tackle.Lib.LLM.select/2`) resolve the
  `:models` references, so an unknown model fails here.
  """
  @spec new(keyword() | t() | nil, [Tackle.Lib.LLM.Provider.source()]) ::
          {:ok, t() | nil} | {:error, term()}
  def new(nil, _providers), do: {:ok, nil}

  def new(%__MODULE__{} = review, providers),
    do: review |> Map.from_struct() |> Map.to_list() |> new(providers)

  def new(opts, providers) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, thinking} <- stage_map(opts, :thinking, @stages, &valid_level?/1),
         {:ok, models} <- stage_map(opts, :models, @stages, &valid_model_ref?/1),
         :ok <- resolve_models(models, providers),
         {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, max_steps} <- stage_map(opts, :max_steps, @step_stages, &positive_integer?/1),
         {:ok, default_rules} <- default_rules(Keyword.get(opts, :default_rules)) do
      {:ok,
       %__MODULE__{
         thinking: thinking,
         models: models,
         profile: profile,
         max_steps: max_steps,
         default_rules: default_rules
       }}
    end
  end

  def new(other, _providers), do: {:error, {:invalid_option, :review, other}}

  defp validate_options(opts) do
    cond do
      not Keyword.keyword?(opts) -> {:error, {:invalid_option, :review, opts}}
      (unknown = Keyword.keys(opts) -- @option_keys) != [] -> invalid(Enum.uniq(unknown))
      true -> :ok
    end
  end

  defp stage_map(opts, key, stages, valid?) do
    case Keyword.get(opts, key, %{}) do
      value when is_map(value) or is_list(value) ->
        if Enum.all?(value, &valid_entry?(&1, stages, valid?)),
          do: {:ok, Map.new(value)},
          else: invalid([{key, value}])

      value ->
        invalid([{key, value}])
    end
  end

  defp valid_entry?({stage, value}, stages, valid?), do: stage in stages and valid?.(value)
  defp valid_entry?(_entry, _stages, _valid?), do: false

  defp valid_level?(level), do: Thinking.validate(level) == :ok
  defp valid_model_ref?(ref), do: is_binary(ref) and ref != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp resolve_models(models, providers) do
    Enum.reduce_while(models, :ok, fn {_stage, ref}, :ok ->
      case LLM.select(providers, ref) do
        {:ok, _selection} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp profile(nil), do: {:ok, nil}

  defp profile(profile) do
    if profile in Rank.profiles(), do: {:ok, profile}, else: invalid(profile: profile)
  end

  defp default_rules(nil), do: {:ok, nil}

  defp default_rules(ids) when is_list(ids) do
    known = Rules.builtin_ids()

    cond do
      not Enum.all?(ids, &is_binary/1) -> invalid(default_rules: ids)
      (unknown = Enum.uniq(ids) -- known) != [] -> {:error, {:unknown_default_rules, unknown}}
      true -> {:ok, Enum.uniq(ids)}
    end
  end

  defp default_rules(ids), do: invalid(default_rules: ids)

  defp invalid(detail), do: {:error, {:invalid_option, :review, detail}}
end
