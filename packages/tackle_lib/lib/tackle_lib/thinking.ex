defmodule Tackle.Lib.Thinking do
  @moduledoc """
  Provider-neutral thinking levels, shared by hosts, frontends, and adapters.

  The levels, from least to most reasoning, are `"off"`, `"minimal"`,
  `"low"`, `"medium"`, `"high"`, `"xhigh"`, and `"max"`. Hosts store one in
  the adapter options as `:reasoning_effort` (`put_llm_opts/2`); `"off"`
  removes the option instead of sending a provider-specific disabled value.

  Every adapter accepts every level. A provider or model that supports fewer
  levels gets the nearest one it does support (`nearest/2`), and each adapter
  documents its mapping, so a level a frontend offers never fails a turn.
  Adapters without configurable reasoning ignore the option.
  """

  @levels ~w(off minimal low medium high xhigh max)
  @reasoning_levels tl(@levels)

  @typedoc "A thinking level, one of `levels/0`."
  @type level :: String.t()

  @doc "Returns the thinking levels in frontend display order."
  @spec levels() :: [level(), ...]
  def levels, do: @levels

  @doc "Validates a thinking level."
  @spec validate(term()) :: :ok | {:error, {:invalid_thinking_level, term()}}
  def validate(level) when level in @levels, do: :ok
  def validate(level), do: {:error, {:invalid_thinking_level, level}}

  @doc """
  Reads a `:reasoning_effort` option value as a thinking level.

  Accepts a level as a string or an atom; `"none"` (or `:none`) is `"off"`.
  An absent value (`nil`) is `{:ok, nil}`, so adapters can tell "no
  preference" from an explicit `"off"`. Anything else is an error adapters
  return as is.

      iex> Tackle.Lib.Thinking.parse(:high)
      {:ok, "high"}

      iex> Tackle.Lib.Thinking.parse(:none)
      {:ok, "off"}

      iex> Tackle.Lib.Thinking.parse("ultra")
      {:error, {:invalid_reasoning_effort, "ultra"}}
  """
  @spec parse(term()) :: {:ok, level() | nil} | {:error, {:invalid_reasoning_effort, term()}}
  def parse(nil), do: {:ok, nil}
  def parse(effort) when effort in [:none, "none"], do: {:ok, "off"}
  def parse(effort) when effort in @levels, do: {:ok, effort}

  def parse(effort) when is_atom(effort) do
    case Atom.to_string(effort) do
      level when level in @levels -> {:ok, level}
      _other -> {:error, {:invalid_reasoning_effort, effort}}
    end
  end

  def parse(effort), do: {:error, {:invalid_reasoning_effort, effort}}

  @doc """
  Returns the level in `supported` nearest to `level`.

  `supported` lists the reasoning levels (not `"off"`) a provider or model
  accepts, in any order. A supported level is returned unchanged; otherwise
  the closest one in `levels/0` order wins, and of two equally close levels
  the lower one, so a request never reasons more than asked for unless the
  model offers nothing lower.

      iex> Tackle.Lib.Thinking.nearest("minimal", ["low", "medium", "high"])
      "low"

      iex> Tackle.Lib.Thinking.nearest("xhigh", ["low", "medium", "high", "max"])
      "high"
  """
  @spec nearest(level(), [level(), ...]) :: level()
  def nearest(level, [_ | _] = supported) when level in @reasoning_levels do
    unless Enum.all?(supported, &(&1 in @reasoning_levels)) do
      raise ArgumentError, "supported levels must be reasoning levels, got: #{inspect(supported)}"
    end

    target = rank(level)
    Enum.min_by(supported, &{abs(rank(&1) - target), rank(&1)})
  end

  @doc """
  Reads the configured thinking level from adapter options.

  Returns `"off"` when the option is absent, disabled, or not a level (such
  as a provider-specific value a host set directly).
  """
  @spec from_llm_opts(keyword()) :: level()
  def from_llm_opts(opts) when is_list(opts) do
    case parse(Keyword.get(opts, :reasoning_effort)) do
      {:ok, level} when is_binary(level) -> level
      _off_or_unknown -> "off"
    end
  end

  @doc "Sets or removes the `:reasoning_effort` option in adapter options."
  @spec put_llm_opts(keyword(), level()) ::
          {:ok, keyword()} | {:error, {:invalid_thinking_level, term()}}
  def put_llm_opts(opts, level) when is_list(opts) do
    with :ok <- validate(level) do
      opts = Keyword.delete(opts, :reasoning_effort)

      case level do
        "off" -> {:ok, opts}
        level -> {:ok, opts ++ [reasoning_effort: level]}
      end
    end
  end

  defp rank(level), do: Enum.find_index(@levels, &(&1 == level))
end
