defmodule Tackle.Thinking do
  @moduledoc """
  Provider-neutral thinking levels exposed by the harness and its frontends.

  Adapters may ignore the resulting `:reasoning_effort` option when they do not
  support configurable reasoning. `"off"` removes reasoning options instead of
  sending a provider-specific disabled value.
  """

  @levels ~w(off minimal low medium high xhigh)

  @doc "Returns the thinking levels in frontend display order."
  @spec levels() :: [String.t(), ...]
  def levels, do: @levels

  @doc "Validates a thinking level."
  @spec validate(term()) :: :ok | {:error, {:invalid_thinking_level, term()}}
  def validate(level) when level in @levels, do: :ok
  def validate(level), do: {:error, {:invalid_thinking_level, level}}

  @doc "Reads the configured thinking level from adapter options."
  @spec from_llm_opts(keyword()) :: String.t()
  def from_llm_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil -> "off"
      level when level in @levels -> level
      level when is_atom(level) -> Atom.to_string(level)
      _level -> "off"
    end
  end

  @doc "Sets or removes reasoning options in adapter options."
  @spec put_llm_opts(keyword(), String.t()) ::
          {:ok, keyword()} | {:error, {:invalid_thinking_level, term()}}
  def put_llm_opts(opts, level) when is_list(opts) do
    with :ok <- validate(level) do
      opts = Keyword.drop(opts, [:reasoning_effort, :reasoning_summary])

      case level do
        "off" -> {:ok, opts}
        level -> {:ok, opts ++ [reasoning_effort: level, reasoning_summary: "auto"]}
      end
    end
  end
end
