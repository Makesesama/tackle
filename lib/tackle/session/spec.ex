defmodule Tackle.Session.Spec do
  @moduledoc """
  Trusted description of one durable session attached to a runtime scope.

  A durable root scope owns exactly one journal. The spec carries the durable
  session identity, the storage location, optional parent lineage for a fork,
  the explicit repair policy, and the metadata recorded in `session.created`.

  This value is produced by trusted host code. Model- or file-generated data may
  choose a session id to resume but can never construct storage paths outside
  the configured `TACKLE_HOME`.
  """

  alias Tackle.Runtime.ID
  alias Tackle.Session.Storage

  @enforce_keys []
  defstruct session_id: nil,
            cwd: nil,
            parent: nil,
            repair: false,
            title: nil,
            tags: [],
            model_ref: nil,
            thinking: nil,
            override_config: false,
            tree: true,
            storage: []

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          parent: %{session_id: String.t(), seq: non_neg_integer()} | nil,
          repair: boolean(),
          title: String.t() | nil,
          tags: [String.t()],
          model_ref: String.t() | nil,
          thinking: String.t() | nil,
          override_config: boolean(),
          tree: boolean(),
          storage: keyword()
        }

  @doc "Builds and validates a durable session request."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{} = opts) do
    spec = %__MODULE__{
      session_id: Map.get(opts, :session_id),
      cwd: Map.get(opts, :cwd),
      parent: Map.get(opts, :parent),
      repair: Map.get(opts, :repair, false),
      title: Map.get(opts, :title),
      tags: Map.get(opts, :tags, []),
      model_ref: Map.get(opts, :model_ref),
      thinking: Map.get(opts, :thinking),
      override_config: Map.get(opts, :override_config, false),
      tree: Map.get(opts, :tree, true),
      storage: Map.get(opts, :storage, [])
    }

    validate(spec)
  end

  def new(value), do: {:error, {:invalid_session_spec, value}}

  @doc "Builds a validated durable session request or raises."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(value) do
    case new(value) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid session spec: #{inspect(reason)}"
    end
  end

  @doc "Returns the durable session id, minting one when the spec omits it."
  @spec session_id(t()) :: String.t()
  def session_id(%__MODULE__{session_id: nil}), do: ID.generate()
  def session_id(%__MODULE__{session_id: session_id}), do: session_id

  @doc "Returns the resolved storage options for this session."
  @spec storage(t()) :: keyword()
  def storage(%__MODULE__{storage: storage}), do: storage

  @doc "Returns the same spec with a concrete session id."
  @spec with_session_id(t(), String.t()) :: t()
  def with_session_id(%__MODULE__{} = spec, session_id), do: %{spec | session_id: session_id}

  defp validate(%__MODULE__{} = spec) do
    with :ok <- validate_session_id(spec.session_id),
         :ok <- validate_optional_string(:cwd, spec.cwd),
         :ok <- validate_parent(spec.parent),
         :ok <- validate_boolean(:repair, spec.repair),
         :ok <- validate_optional_string(:title, spec.title),
         :ok <- validate_tags(spec.tags),
         :ok <- validate_optional_string(:model_ref, spec.model_ref),
         :ok <- validate_optional_string(:thinking, spec.thinking),
         :ok <- validate_boolean(:override_config, spec.override_config),
         :ok <- validate_boolean(:tree, spec.tree),
         :ok <- validate_storage(spec.storage) do
      {:ok, spec}
    end
  end

  defp validate_session_id(nil), do: :ok

  defp validate_session_id(session_id), do: Storage.validate_session_id(session_id)

  defp validate_parent(nil), do: :ok

  defp validate_parent(%{session_id: session_id, seq: seq})
       when is_binary(session_id) and is_integer(seq) and seq >= 0 do
    case Storage.validate_session_id(session_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_parent, reason}}
    end
  end

  defp validate_parent(other), do: {:error, {:invalid_parent, other}}

  defp validate_optional_string(_name, nil), do: :ok
  defp validate_optional_string(_name, value) when is_binary(value), do: :ok
  defp validate_optional_string(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_boolean(_name, value) when is_boolean(value), do: :ok
  defp validate_boolean(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, {:invalid_tags, tags}}
    end
  end

  defp validate_tags(tags), do: {:error, {:invalid_tags, tags}}

  defp validate_storage(storage) when is_list(storage) do
    if Keyword.keyword?(storage) do
      :ok
    else
      {:error, {:invalid_storage, storage}}
    end
  end

  defp validate_storage(storage), do: {:error, {:invalid_storage, storage}}
end
