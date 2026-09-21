defmodule Tackle.Runtime.ScopeSpec do
  @moduledoc """
  Trusted description of one root-agent scope and its allowlisted profiles.

  `:backend` is the host adapter for every agent in the scope. `:session` is an
  opaque backend option retained for compatibility with the root harness; SaaS
  hosts may use it for their own root-session specification.
  """

  alias Tackle.Runtime.AgentBackend
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeRef

  @enforce_keys [:root_spec, :backend]
  defstruct scope_ref: nil,
            root_spec: nil,
            backend: nil,
            limits: nil,
            profiles: %{},
            session: nil

  @type resolver :: (-> {:ok, AgentSpec.t()} | {:error, term()})

  @type t :: %__MODULE__{
          scope_ref: ScopeRef.t(),
          root_spec: AgentSpec.t(),
          backend: module(),
          limits: Limits.t(),
          profiles: %{optional(String.t()) => AgentSpec.t() | resolver()},
          session: term()
        }

  @doc "Builds a validated scope spec, minting a scope id when absent."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{} = opts) do
    backend = Map.get(opts, :backend) || Application.get_env(:tackle_runtime, :default_backend)

    with {:ok, backend} <- validate_backend(backend),
         {:ok, raw_root_spec} <- fetch_root_spec(opts),
         {:ok, root_spec} <- validate_agent_spec(backend, raw_root_spec),
         {:ok, limits} <- Limits.new(Map.get(opts, :limits, Limits.default())),
         {:ok, profiles} <- validate_profiles(backend, Map.get(opts, :profiles, %{})),
         {:ok, scope_ref} <- scope_ref(Map.get(opts, :scope_ref)) do
      {:ok,
       %__MODULE__{
         scope_ref: scope_ref,
         root_spec: root_spec,
         backend: backend,
         limits: limits,
         profiles: profiles,
         session: Map.get(opts, :session)
       }}
    end
  end

  def new(value), do: {:error, {:invalid_scope_spec, value}}

  @doc "Builds a validated scope spec or raises."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(value) do
    case new(value) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid scope spec: #{inspect(reason)}"
    end
  end

  @doc "Resolves an allowlisted profile into a backend-validated agent spec."
  @spec resolve_profile(t(), String.t()) :: {:ok, AgentSpec.t()} | {:error, term()}
  def resolve_profile(%__MODULE__{profiles: profiles, backend: backend}, name)
      when is_binary(name) do
    case Map.fetch(profiles, name) do
      {:ok, %AgentSpec{} = spec} -> validate_agent_spec(backend, spec)
      {:ok, resolver} when is_function(resolver, 0) -> resolve_fun(backend, resolver, name)
      :error -> {:error, {:unknown_profile, name}}
    end
  end

  def resolve_profile(%__MODULE__{}, name), do: {:error, {:invalid_profile, name}}

  defp resolve_fun(backend, resolver, name) do
    case resolver.() do
      {:ok, %AgentSpec{} = spec} -> validate_agent_spec(backend, spec)
      {:error, reason} -> {:error, {:profile_failed, name, reason}}
      other -> {:error, {:invalid_profile_result, name, other}}
    end
  rescue
    exception -> {:error, {:profile_failed, name, Exception.message(exception)}}
  end

  defp validate(%__MODULE__{} = spec) do
    with {:ok, backend} <- validate_backend(spec.backend),
         {:ok, root_spec} <- validate_agent_spec(backend, spec.root_spec),
         {:ok, limits} <- Limits.new(spec.limits || Limits.default()),
         {:ok, profiles} <- validate_profiles(backend, spec.profiles),
         {:ok, scope_ref} <- scope_ref(spec.scope_ref) do
      {:ok,
       %{
         spec
         | backend: backend,
           scope_ref: scope_ref,
           root_spec: root_spec,
           limits: limits,
           profiles: profiles
       }}
    end
  end

  defp validate_backend(nil), do: {:error, {:missing_scope_spec, :backend}}

  defp validate_backend(backend) when is_atom(backend) do
    case Code.ensure_loaded(backend) do
      {:module, ^backend} -> {:ok, backend}
      {:error, reason} -> {:error, {:agent_backend_unavailable, backend, reason}}
    end
  end

  defp validate_backend(value), do: {:error, {:invalid_agent_backend, value}}

  defp validate_agent_spec(backend, value) do
    with {:ok, spec} <- AgentSpec.new(value),
         :ok <- AgentBackend.validate_spec(backend, spec) do
      {:ok, spec}
    end
  end

  defp fetch_root_spec(opts) do
    case Map.fetch(opts, :root_spec) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_scope_spec, :root_spec}}
    end
  end

  defp scope_ref(nil), do: ScopeRef.new(ID.generate())
  defp scope_ref(value), do: ScopeRef.new(value)

  defp validate_profiles(backend, profiles) when is_map(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn
      {name, value}, {:ok, acc} when is_binary(name) and name != "" ->
        case validate_profile(backend, name, value) do
          {:ok, profile} -> {:cont, {:ok, Map.put(acc, name, profile)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {name, _value}, _acc ->
        {:halt, {:error, {:invalid_profile_name, name}}}
    end)
  end

  defp validate_profiles(_backend, value), do: {:error, {:invalid_profiles, value}}

  defp validate_profile(backend, _name, %AgentSpec{} = spec),
    do: validate_agent_spec(backend, spec)

  defp validate_profile(_backend, _name, resolver) when is_function(resolver, 0),
    do: {:ok, resolver}

  defp validate_profile(_backend, name, value),
    do: {:error, {:invalid_profile, name, value}}
end
