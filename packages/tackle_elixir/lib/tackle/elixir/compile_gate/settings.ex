defmodule Tackle.Elixir.CompileGate.Settings do
  @moduledoc """
  Settings of `Tackle.Elixir.CompileGate`.

    * `:enabled` - whether the gate runs (default `true`).
    * `:max_rounds` - how many times one turn may be continued with
      diagnostics (default `2`). `0` checks and logs without continuing the
      turn, to measure what the gate would do.
    * `:timeout_seconds` - how long the gate waits for one compile in the
      project node (default `120`); a compile that takes longer is skipped,
      not reported.
    * `:warnings` - whether new warnings are reported, not only errors
      (default `true`).
    * `:log_path` - a file to which every decision is appended as a JSON
      line (default `nil`, no log).
  """

  defstruct enabled: true, max_rounds: 2, timeout_ms: 120_000, warnings: true, log_path: nil

  @type t :: %__MODULE__{
          enabled: boolean(),
          max_rounds: non_neg_integer(),
          timeout_ms: pos_integer(),
          warnings: boolean(),
          log_path: Path.t() | nil
        }

  @option_keys [:enabled, :max_rounds, :timeout_seconds, :warnings, :log_path]

  @doc """
  Validates settings. `nil` gives the defaults; `false`, or `enabled: false`,
  gives `nil`: the gate is off.
  """
  @spec new(nil | false | keyword() | t()) :: {:ok, t() | nil} | {:error, term()}
  def new(nil), do: {:ok, %__MODULE__{}}
  def new(false), do: {:ok, nil}
  def new(%__MODULE__{enabled: false}), do: {:ok, nil}
  def new(%__MODULE__{} = settings), do: {:ok, settings}

  def new(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_keys(opts),
         {:ok, enabled} <- boolean(opts, :enabled, true),
         {:ok, max_rounds} <- max_rounds(opts),
         {:ok, timeout_ms} <- timeout_ms(opts),
         {:ok, warnings} <- boolean(opts, :warnings, true),
         {:ok, log_path} <- log_path(opts) do
      settings = %__MODULE__{
        enabled: enabled,
        max_rounds: max_rounds,
        timeout_ms: timeout_ms,
        warnings: warnings,
        log_path: log_path
      }

      new(settings)
    end
  end

  def new(other), do: {:error, {:invalid_option, :compile_gate, other}}

  defp validate_keyword(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, {:invalid_option, :compile_gate, opts}}
  end

  defp validate_keys(opts) do
    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_option, :compile_gate, {:unknown_keys, Enum.uniq(unknown)}}}
    end
  end

  defp boolean(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      value -> invalid(key, value)
    end
  end

  defp max_rounds(opts) do
    case Keyword.get(opts, :max_rounds, 2) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> invalid(:max_rounds, value)
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_seconds, 120) do
      value when is_number(value) and value > 0 -> {:ok, max(round(value * 1_000), 1)}
      value -> invalid(:timeout_seconds, value)
    end
  end

  defp log_path(opts) do
    case Keyword.get(opts, :log_path) do
      nil -> {:ok, nil}
      path when is_binary(path) and path != "" -> {:ok, path}
      value -> invalid(:log_path, value)
    end
  end

  defp invalid(key, value), do: {:error, {:invalid_option, :compile_gate, {key, value}}}
end
