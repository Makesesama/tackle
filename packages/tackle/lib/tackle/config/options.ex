defmodule Tackle.Config.Options do
  @moduledoc false

  # The shared skeleton of the switchable sub-configurations
  # (`Tackle.Config.SessionTitles`, `Watchdog`, `Narration`): `nil`, `false`,
  # and `enabled: false` turn the feature off; otherwise a keyword list with
  # known keys is built by the module's own function. Every error is
  # `{:invalid_option, name, detail}`.

  # The longest Erlang timer, `2^32 - 1` milliseconds, in seconds.
  @max_seconds 4_294_967_295 / 1_000

  @doc """
  Builds the sub-configuration `name` from `value` with `build`, or returns
  `{:ok, nil}` when it is off. `keys` are the accepted options besides
  `:enabled`.
  """
  @spec new(term(), atom(), [atom()], (keyword() -> {:ok, struct()} | {:error, term()})) ::
          {:ok, struct() | nil} | {:error, term()}
  def new(nil, _name, _keys, _build), do: {:ok, nil}
  def new(false, _name, _keys, _build), do: {:ok, nil}

  def new(opts, name, keys, build) when is_list(opts) do
    with :ok <- validate_keys(opts, name, [:enabled | keys]),
         {:ok, enabled} <- fetch_enabled(opts, name) do
      if enabled, do: build.(Keyword.delete(opts, :enabled)), else: {:ok, nil}
    end
  end

  def new(other, name, _keys, _build), do: invalid(name, other)

  @doc "Fetches a required, non-empty model reference."
  @spec fetch_model(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def fetch_model(opts, name) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      model -> invalid(name, model: model)
    end
  end

  @doc """
  Fetches a positive number of seconds that fits the longest Erlang timer,
  4,294,967.295 seconds.
  """
  @spec fetch_seconds(keyword(), atom(), atom(), number()) :: {:ok, number()} | {:error, term()}
  def fetch_seconds(opts, name, key, default) do
    case Keyword.get(opts, key, default) do
      seconds when is_number(seconds) and seconds > 0 and seconds <= @max_seconds ->
        {:ok, seconds}

      seconds ->
        invalid(name, [{key, seconds}])
    end
  end

  @doc "Converts seconds to timer milliseconds, at least one."
  @spec to_ms(number()) :: pos_integer()
  def to_ms(seconds), do: max(round(seconds * 1_000), 1)

  @doc "The error for an invalid sub-configuration."
  @spec invalid(atom(), term()) :: {:error, {:invalid_option, atom(), term()}}
  def invalid(name, detail), do: {:error, {:invalid_option, name, detail}}

  defp validate_keys(opts, name, keys) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- keys do
        [] -> :ok
        unknown -> invalid(name, Enum.uniq(unknown))
      end
    else
      invalid(name, opts)
    end
  end

  defp fetch_enabled(opts, name) do
    case Keyword.get(opts, :enabled, true) do
      enabled when is_boolean(enabled) -> {:ok, enabled}
      enabled -> invalid(name, enabled: enabled)
    end
  end
end
