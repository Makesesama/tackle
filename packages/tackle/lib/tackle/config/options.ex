defmodule Tackle.Config.Options do
  @moduledoc false

  # Checks shared by `Tackle.Config` and its parts, and the shared skeleton of
  # the switchable sub-configurations
  # (`Tackle.Config.SessionTitles`, `Watchdog`, `Narration`): `nil`, `false`,
  # and `enabled: false` turn the feature off; otherwise a keyword list with
  # known keys is built by the module's own function. Every error is
  # `{:invalid_option, name, detail}`.

  alias Tackle.Executor

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

  @doc """
  Checks a session context: a map whose `:executor`, if any, is an executor
  module and its config. Tools fall back to the local executor when
  `context.executor` is absent, so a malformed value must fail here rather
  than silently run unjailed.
  """
  @spec validate_context(term()) :: :ok | {:error, term()}
  def validate_context(context) when is_map(context), do: validate_executor(context)
  def validate_context(context), do: {:error, {:invalid_option, :context, context}}

  defp validate_executor(%{executor: {module, _config} = executor}) when is_atom(module) do
    if executor_module?(module), do: :ok, else: {:error, {:invalid_option, :executor, executor}}
  end

  defp validate_executor(%{executor: executor}),
    do: {:error, {:invalid_option, :executor, executor}}

  defp validate_executor(_context), do: :ok

  # Optional callbacks, such as `input/3`, are not required.
  defp executor_module?(module) do
    required =
      Executor.behaviour_info(:callbacks) -- Executor.behaviour_info(:optional_callbacks)

    Code.ensure_loaded?(module) and
      Enum.all?(required, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  @doc """
  Checks an option list: a keyword list without repeated or unknown keys.
  `errors` names the error tags for each of those failures.
  """
  @spec validate_list(term(), [atom()], {atom(), atom(), atom()}) :: :ok | {:error, term()}
  def validate_list(opts, known_keys, {invalid, duplicate, unknown}) do
    if is_list(opts) and Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      case {keys -- Enum.uniq(keys), Enum.uniq(keys -- known_keys)} do
        {[key | _rest], _unknown} -> {:error, {duplicate, key}}
        {[], []} -> :ok
        {[], unknown_keys} -> {:error, {unknown, unknown_keys}}
      end
    else
      {:error, {invalid, opts}}
    end
  end

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
