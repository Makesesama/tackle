defmodule Tackle.Lib.Compaction.Config do
  @moduledoc """
  Per-session compaction configuration.

  Compaction is opt-in: `Tackle.Lib.State` carries no compaction config unless a
  host supplies one. The root harness supplies an enabled config by default and
  installs its durable committer.

  A config bundles the trigger policy, the summarizer module, the durability
  committer, optional operator instructions, and how many tightening passes a
  single compaction may run.
  """

  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.Compaction.Summarizer

  @default_summarizer Summarizer.LLM

  @type t :: %__MODULE__{
          enabled?: boolean(),
          policy: Policy.t(),
          summarizer: module(),
          committer: module() | nil,
          instructions: String.t() | nil,
          max_passes: pos_integer()
        }

  defstruct enabled?: true,
            policy: nil,
            summarizer: @default_summarizer,
            committer: nil,
            instructions: nil,
            max_passes: 1

  @doc "Builds and validates a compaction config from options."
  @spec new(keyword() | t() | false | nil) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = config), do: validate(config)
  def new(false), do: {:ok, %{new!() | enabled?: false}}
  def new(nil), do: {:ok, new!()}

  def new(opts) when is_list(opts) do
    policy_opts = Keyword.get(opts, :policy, [])

    with {:ok, policy} <- policy_from(policy_opts) do
      config = %__MODULE__{
        enabled?: Keyword.get(opts, :enabled?, true),
        policy: policy,
        summarizer: Keyword.get(opts, :summarizer, @default_summarizer),
        committer: Keyword.get(opts, :committer),
        instructions: Keyword.get(opts, :instructions),
        max_passes: Keyword.get(opts, :max_passes, 1)
      }

      validate(config)
    end
  end

  def new(opts), do: {:error, {:invalid_compaction_config, opts}}

  @doc "Builds and validates a compaction config, raising on invalid options."
  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid compaction config: #{inspect(reason)}"
    end
  end

  @doc "Returns true when this config enables compaction."
  @spec enabled?(t() | nil) :: boolean()
  def enabled?(%__MODULE__{enabled?: enabled?}), do: enabled?
  def enabled?(_config), do: false

  @doc "Returns a config with the given durability committer installed."
  @spec put_committer(t(), module() | nil) :: t()
  def put_committer(%__MODULE__{} = config, committer), do: %{config | committer: committer}

  defp policy_from(%Policy{} = policy), do: {:ok, policy}
  defp policy_from(nil), do: {:ok, Policy.new!([])}
  defp policy_from(opts) when is_list(opts), do: Policy.new(opts)
  defp policy_from(other), do: {:error, {:invalid_compaction_policy, other}}

  defp validate(%__MODULE__{} = config) do
    with :ok <- validate_boolean(:enabled?, config.enabled?),
         :ok <- validate_policy(config.policy),
         :ok <- validate_module(:summarizer, config.summarizer, :summarize, 2),
         :ok <- validate_committer(config.committer),
         :ok <- validate_instructions(config.instructions),
         :ok <- validate_max_passes(config.max_passes) do
      {:ok, config}
    end
  end

  defp validate_boolean(_field, value) when is_boolean(value), do: :ok
  defp validate_boolean(field, value), do: {:error, {:invalid_compaction_config, {field, value}}}

  defp validate_policy(%Policy{}), do: :ok
  defp validate_policy(value), do: {:error, {:invalid_compaction_config, {:policy, value}}}

  defp validate_committer(nil), do: :ok
  defp validate_committer(module), do: validate_module(:committer, module, :commit, 2)

  defp validate_module(_field, module, fun, arity)
       when is_atom(module) and not is_nil(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_compaction_module, module, :not_loaded}}

      not function_exported?(module, fun, arity) ->
        {:error, {:invalid_compaction_module, module, {:missing_callback, {fun, arity}}}}

      true ->
        :ok
    end
  end

  defp validate_module(field, module, _fun, _arity),
    do: {:error, {:invalid_compaction_config, {field, module}}}

  defp validate_instructions(nil), do: :ok
  defp validate_instructions(value) when is_binary(value), do: :ok

  defp validate_instructions(value),
    do: {:error, {:invalid_compaction_config, {:instructions, value}}}

  defp validate_max_passes(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_passes(value),
    do: {:error, {:invalid_compaction_config, {:max_passes, value}}}
end
