defmodule Tackle.Runtime.ScopeSpec do
  @moduledoc """
  Trusted description of one root-agent scope and its allowlisted profiles.

  The root scope owns the root agent plus every descendant. `:profiles` is the
  trusted allowlist a model may select from by name; it is never supplied by
  model output. Each profile value is an already-resolved `AgentSpec` or a
  zero-arity resolver returning `{:ok, AgentSpec.t()} | {:error, term()}`.
  """

  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeRef

  @enforce_keys [:root_spec]
  defstruct scope_ref: nil,
            root_spec: nil,
            limits: nil,
            profiles: %{},
            session: nil

  @type resolver :: (-> {:ok, AgentSpec.t()} | {:error, term()})

  @type t :: %__MODULE__{
          scope_ref: ScopeRef.t(),
          root_spec: AgentSpec.t(),
          limits: Limits.t(),
          profiles: %{optional(String.t()) => AgentSpec.t() | resolver()},
          session: Tackle.Session.Spec.t() | nil
        }

  @doc "Builds a validated scope spec, minting a scope id when absent."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{} = opts) do
    with {:ok, raw_root_spec} <- fetch_root_spec(opts),
         {:ok, root_spec} <- AgentSpec.new(raw_root_spec),
         {:ok, limits} <- Limits.new(Map.get(opts, :limits, Limits.default())),
         {:ok, profiles} <- validate_profiles(Map.get(opts, :profiles, %{})),
         {:ok, session} <- validate_session(Map.get(opts, :session)),
         {:ok, scope_ref} <- scope_ref(Map.get(opts, :scope_ref)) do
      {:ok,
       %__MODULE__{
         scope_ref: scope_ref,
         root_spec: root_spec,
         limits: limits,
         profiles: profiles,
         session: session
       }}
    else
      {:error, _reason} = error -> error
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

  @doc """
  Resolves an allowlisted profile name into an `AgentSpec`.

  Unknown names and resolver failures are explicit errors; a name is never
  loaded as a module.
  """
  @spec resolve_profile(t(), String.t()) :: {:ok, AgentSpec.t()} | {:error, term()}
  def resolve_profile(%__MODULE__{profiles: profiles}, name) when is_binary(name) do
    case Map.fetch(profiles, name) do
      {:ok, %AgentSpec{} = spec} -> {:ok, spec}
      {:ok, resolver} when is_function(resolver, 0) -> resolve_fun(resolver, name)
      :error -> {:error, {:unknown_profile, name}}
    end
  end

  def resolve_profile(%__MODULE__{}, name), do: {:error, {:invalid_profile, name}}

  defp resolve_fun(resolver, name) do
    case resolver.() do
      {:ok, %AgentSpec{} = spec} -> {:ok, spec}
      {:error, reason} -> {:error, {:profile_failed, name, reason}}
      other -> {:error, {:invalid_profile_result, name, other}}
    end
  rescue
    exception -> {:error, {:profile_failed, name, Exception.message(exception)}}
  end

  defp validate(%__MODULE__{scope_ref: scope_ref} = spec) do
    with {:ok, root_spec} <- AgentSpec.new(spec.root_spec),
         {:ok, limits} <- Limits.new(spec.limits || Limits.default()),
         {:ok, profiles} <- validate_profiles(spec.profiles),
         {:ok, session} <- validate_session(spec.session),
         {:ok, scope_ref} <- scope_ref(scope_ref) do
      {:ok,
       %{
         spec
         | scope_ref: scope_ref,
           root_spec: root_spec,
           limits: limits,
           profiles: profiles,
           session: session
       }}
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

  defp validate_profiles(profiles) when is_map(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn
      {name, value}, {:ok, acc} when is_binary(name) and name != "" ->
        case validate_profile(name, value) do
          {:ok, profile} -> {:cont, {:ok, Map.put(acc, name, profile)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {name, _value}, _acc ->
        {:halt, {:error, {:invalid_profile_name, name}}}
    end)
  end

  defp validate_profiles(value), do: {:error, {:invalid_profiles, value}}

  defp validate_profile(_name, %AgentSpec{} = spec), do: AgentSpec.new(spec)
  defp validate_profile(_name, resolver) when is_function(resolver, 0), do: {:ok, resolver}
  defp validate_profile(name, value), do: {:error, {:invalid_profile, name, value}}

  defp validate_session(nil), do: {:ok, nil}

  defp validate_session(%Tackle.Session.Spec{} = session) do
    Tackle.Session.Spec.new(session)
  end

  defp validate_session(value), do: {:error, {:invalid_session, value}}
end
