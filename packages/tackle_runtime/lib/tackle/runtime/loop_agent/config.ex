defmodule Tackle.Runtime.LoopAgent.Config do
  @moduledoc """
  Trusted, in-memory configuration of a `Tackle.Runtime.LoopAgent`.

  Build it with `new/1` from host data the host has already authorized. The
  model always resolves against the configuration's own `:providers`, so a
  delegated request or a reconfiguration can only pick a model the host
  offered.
  """

  alias Tackle.Lib.Hook
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Thinking

  @enforce_keys [:providers, :model_ref, :llm]
  defstruct [
    :providers,
    :model_ref,
    :llm,
    credential_store: nil,
    tools: [],
    hooks: [],
    system_prompt: "",
    context: %{},
    llm_opts: [],
    max_steps: nil
  ]

  @type t :: %__MODULE__{
          providers: [LLM.Provider.source()],
          model_ref: String.t(),
          llm: term(),
          credential_store: Tackle.Lib.CredentialStore.handle() | nil,
          tools: [module()],
          hooks: [module()],
          system_prompt: String.t(),
          context: map(),
          llm_opts: keyword(),
          max_steps: pos_integer() | nil
        }

  @doc """
  Builds a configuration.

  Required: `:providers` (`Tackle.Lib.LLM.Provider` sources) and `:model`
  (`"provider/model"`, resolved against them; there is no implicit model).

  Optional: `:tools`, `:hooks` (`Tackle.Lib.Hook` modules, for example a
  host's persistence or billing hooks), `:system_prompt`, `:context`,
  `:llm_opts`, `:thinking`, `:max_steps`, and `:credential_store`. A
  credential store handle is put into the adapter options of every model call
  and cannot be replaced through `configure/2`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, providers} <- fetch(opts, :providers),
         {:ok, model} <- fetch(opts, :model),
         {:ok, llm} <- LLM.select(providers, model),
         {:ok, llm_opts} <- fetch_llm_opts(opts),
         {:ok, llm_opts} <- thinking(llm_opts, opts[:thinking]) do
      config = %__MODULE__{
        providers: providers,
        model_ref: llm.ref,
        llm: llm,
        credential_store: Keyword.get(opts, :credential_store),
        tools: Keyword.get(opts, :tools, []),
        hooks: Keyword.get(opts, :hooks, []),
        system_prompt: Keyword.get(opts, :system_prompt, ""),
        context: Keyword.get(opts, :context, %{}),
        llm_opts: llm_opts,
        max_steps: Keyword.get(opts, :max_steps)
      }

      with :ok <- validate(config), do: {:ok, config}
    end
  end

  def new(opts), do: {:error, {:invalid_agent_options, opts}}

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_llm_opts(opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])
    if Keyword.keyword?(llm_opts), do: {:ok, llm_opts}, else: {:error, :invalid_llm_opts}
  end

  @doc "Checks a configuration's fields."
  @spec validate(t() | term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = config) do
    cond do
      not is_list(config.providers) ->
        {:error, :invalid_providers}

      not is_map(config.context) ->
        {:error, :invalid_agent_context}

      not Keyword.keyword?(config.llm_opts) ->
        {:error, :invalid_llm_opts}

      not module_list?(config.tools) ->
        {:error, :invalid_tools}

      not (is_list(config.hooks) and Enum.all?(config.hooks, &Hook.hook?/1)) ->
        {:error, :invalid_hooks}

      not is_binary(config.system_prompt) ->
        {:error, :invalid_system_prompt}

      not valid_steps?(config.max_steps) ->
        {:error, :invalid_max_steps}

      true ->
        :ok
    end
  end

  def validate(config), do: {:error, {:invalid_agent_config, config}}

  defp module_list?(modules), do: is_list(modules) and Enum.all?(modules, &is_atom/1)

  defp valid_steps?(nil), do: true
  defp valid_steps?(steps), do: is_integer(steps) and steps > 0

  @doc """
  Applies `Tackle.Runtime.AgentBackend.configure_option/0` values in order:
  `:model`, `:thinking`, `:max_steps`, `:context` (merged), and `:llm_opts`
  (merged). Each value is checked; the rest of the configuration is trusted
  to be valid already.
  """
  @spec update(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = config, opts) when is_list(opts) do
    opts
    |> Enum.reduce_while({:ok, config}, fn option, {:ok, config} ->
      case update_option(config, option) do
        {:ok, config} -> {:cont, {:ok, config}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def update(%__MODULE__{}, opts), do: {:error, {:invalid_configure_options, opts}}

  defp update_option(config, {:model, model}) do
    with {:ok, llm} <- LLM.select(config.providers, model) do
      {:ok, %{config | llm: llm, model_ref: llm.ref}}
    end
  end

  defp update_option(config, {:thinking, level}) do
    with {:ok, llm_opts} <- Thinking.put_llm_opts(config.llm_opts, level) do
      {:ok, %{config | llm_opts: llm_opts}}
    end
  end

  defp update_option(config, {:max_steps, steps}) do
    if valid_steps?(steps),
      do: {:ok, %{config | max_steps: steps}},
      else: {:error, :invalid_max_steps}
  end

  defp update_option(config, {:context, context}) when is_map(context),
    do: {:ok, %{config | context: Map.merge(config.context, context)}}

  defp update_option(config, {:llm_opts, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, %{config | llm_opts: Keyword.merge(config.llm_opts, opts)}},
      else: {:error, :invalid_llm_opts}
  end

  defp update_option(_config, {key, _value}) when is_atom(key),
    do: {:error, {:invalid_agent_option, key}}

  defp update_option(_config, option), do: {:error, {:invalid_agent_option, option}}

  @doc """
  The adapter options of a model call: the configured options, with the
  credential store handle, when there is one, always on top.
  """
  @spec llm_opts(t()) :: keyword()
  def llm_opts(%__MODULE__{credential_store: nil, llm_opts: llm_opts}), do: llm_opts

  def llm_opts(%__MODULE__{credential_store: store, llm_opts: llm_opts}),
    do: Keyword.put(llm_opts, :credential_store, store)

  defp thinking(llm_opts, nil), do: {:ok, llm_opts}
  defp thinking(llm_opts, level), do: Thinking.put_llm_opts(llm_opts, level)
end
