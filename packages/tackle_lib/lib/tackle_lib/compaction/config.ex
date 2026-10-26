defmodule Tackle.Lib.Compaction.Config do
  @moduledoc """
  Per-session compaction configuration.

  Compaction is opt-in: a `Tackle.Lib.State` compacts only when its
  `:compaction` is a config, and `nil` there is the one way to say it is
  disabled. The root harness supplies a config by default.

  A config bundles the trigger policy, the summarizer module, optional
  operator instructions, and how many tightening passes a single compaction
  may run. Compactions are made durable through the state's
  `Tackle.Lib.Committer`, not through the config.
  """

  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.Compaction.Summarizer

  @default_summarizer Summarizer.LLM

  @type t :: %__MODULE__{
          policy: Policy.t(),
          summarizer: module(),
          instructions: String.t() | nil,
          max_passes: pos_integer()
        }

  defstruct policy: nil,
            summarizer: @default_summarizer,
            instructions: nil,
            max_passes: 1

  @doc """
  Builds and validates a compaction config from options or an existing config.

  ## Options

    * `:policy` - a `Tackle.Lib.Compaction.Policy` or its options (default:
      the default policy).
    * `:summarizer` - module implementing `Tackle.Lib.Compaction.Summarizer`
      (default: `Tackle.Lib.Compaction.Summarizer.LLM`).
    * `:instructions` - operator instructions added to every summary request.
    * `:max_passes` - tightening passes one compaction may run (default 1).
  """
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = config), do: validate(config)

  def new(opts) when is_list(opts) do
    with {:ok, opts} <- known_options(opts),
         {:ok, policy} <- policy_from(Keyword.get(opts, :policy)) do
      config = %__MODULE__{
        policy: policy,
        summarizer: Keyword.get(opts, :summarizer, @default_summarizer),
        instructions: Keyword.get(opts, :instructions),
        max_passes: Keyword.get(opts, :max_passes, 1)
      }

      validate(config)
    end
  end

  def new(opts), do: {:error, {:invalid_compaction_config, opts}}

  @doc "Builds and validates a compaction config, raising on invalid options."
  @spec new!(keyword() | t()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid compaction config: #{inspect(reason)}"
    end
  end

  @options [:policy, :summarizer, :instructions, :max_passes]

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> {:ok, opts}
      unknown -> {:error, {:invalid_compaction_config, {:unknown_options, unknown}}}
    end
  end

  defp policy_from(%Policy{} = policy), do: {:ok, policy}
  defp policy_from(nil), do: {:ok, Policy.new!([])}
  defp policy_from(opts) when is_list(opts), do: Policy.new(opts)
  defp policy_from(other), do: {:error, {:invalid_compaction_policy, other}}

  defp validate(%__MODULE__{} = config) do
    with :ok <- validate_policy(config.policy),
         :ok <- validate_summarizer(config.summarizer),
         :ok <- validate_instructions(config.instructions),
         :ok <- validate_max_passes(config.max_passes) do
      {:ok, config}
    end
  end

  defp validate_policy(%Policy{}), do: :ok
  defp validate_policy(value), do: {:error, {:invalid_compaction_config, {:policy, value}}}

  defp validate_summarizer(module) when is_atom(module) and not is_nil(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_compaction_module, module, :not_loaded}}

      not function_exported?(module, :summarize, 2) ->
        {:error, {:invalid_compaction_module, module, {:missing_callback, {:summarize, 2}}}}

      true ->
        :ok
    end
  end

  defp validate_summarizer(module),
    do: {:error, {:invalid_compaction_config, {:summarizer, module}}}

  defp validate_instructions(nil), do: :ok
  defp validate_instructions(value) when is_binary(value), do: :ok

  defp validate_instructions(value),
    do: {:error, {:invalid_compaction_config, {:instructions, value}}}

  defp validate_max_passes(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_passes(value),
    do: {:error, {:invalid_compaction_config, {:max_passes, value}}}
end
