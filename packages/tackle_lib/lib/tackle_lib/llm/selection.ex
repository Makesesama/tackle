defmodule Tackle.Lib.LLM.Selection do
  @moduledoc """
  An immutable adapter and model selection.

  Selections are created through `Tackle.Lib.LLM.select/2`. The adapter-local
  `model` is passed to the selected adapter, while `ref` preserves the canonical
  `adapter_id/model` identifier for configuration and auditing.
  """

  @adapter_id_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @enforce_keys [:adapter, :adapter_id, :model, :ref]
  defstruct [:adapter, :adapter_id, :model, :ref]

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_id: String.t(),
          model: String.t(),
          ref: String.t()
        }

  @doc false
  @spec resolve([module()], String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(adapters, model_ref) when is_list(adapters) and is_binary(model_ref) do
    with {:ok, {adapter_id, model}} <- parse_model_ref(model_ref),
         {:ok, adapter_index} <- index_adapters(adapters),
         {:ok, adapter} <- fetch_adapter(adapter_index, adapter_id),
         {:ok, models} <- adapter_models(adapter, adapter_id),
         :ok <- ensure_model(models, adapter_id, model) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         adapter_id: adapter_id,
         model: model,
         ref: model_ref
       }}
    end
  end

  def resolve(_adapters, model_ref), do: {:error, {:invalid_model_ref, model_ref}}

  defp parse_model_ref(model_ref) do
    case String.split(model_ref, "/", parts: 2) do
      [adapter_id, model] when model != "" ->
        if valid_adapter_id?(adapter_id) and model == String.trim(model) do
          {:ok, {adapter_id, model}}
        else
          {:error, {:invalid_model_ref, model_ref}}
        end

      _ ->
        {:error, {:invalid_model_ref, model_ref}}
    end
  end

  defp index_adapters(adapters) do
    Enum.reduce_while(adapters, {:ok, %{}}, fn adapter, {:ok, index} ->
      with :ok <- validate_adapter(adapter),
           {:ok, adapter_id} <- adapter_callback(adapter, :adapter_id),
           :ok <- validate_adapter_id(adapter_id),
           :ok <- ensure_unique_adapter_id(index, adapter_id) do
        {:cont, {:ok, Map.put(index, adapter_id, adapter)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_adapter(adapter) when is_atom(adapter) and not is_nil(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} -> validate_callbacks(adapter)
      {:error, reason} -> {:error, {:invalid_adapter, adapter, {:not_loaded, reason}}}
    end
  end

  defp validate_adapter(adapter), do: {:error, {:invalid_adapter, adapter, :not_a_module}}

  defp validate_callbacks(adapter) do
    required_callbacks = [adapter_id: 0, models: 0, generate: 2]

    case Enum.find(required_callbacks, fn {name, arity} ->
           not function_exported?(adapter, name, arity)
         end) do
      nil -> :ok
      callback -> {:error, {:invalid_adapter, adapter, {:missing_callback, callback}}}
    end
  end

  defp adapter_callback(adapter, callback) do
    {:ok, apply(adapter, callback, [])}
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end

  defp validate_adapter_id(adapter_id) do
    if valid_adapter_id?(adapter_id),
      do: :ok,
      else: {:error, {:invalid_adapter_id, adapter_id}}
  end

  defp valid_adapter_id?(adapter_id),
    do: is_binary(adapter_id) and Regex.match?(@adapter_id_pattern, adapter_id)

  defp ensure_unique_adapter_id(index, adapter_id) do
    if Map.has_key?(index, adapter_id),
      do: {:error, {:duplicate_adapter_id, adapter_id}},
      else: :ok
  end

  defp fetch_adapter(adapter_index, adapter_id) do
    case Map.fetch(adapter_index, adapter_id) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unknown_adapter, adapter_id}}
    end
  end

  defp adapter_models(adapter, adapter_id) do
    with {:ok, models} <- adapter_callback(adapter, :models),
         {:ok, models} <- validate_models(models, adapter_id) do
      {:ok, models}
    end
  end

  defp validate_models(models, adapter_id) when is_list(models) do
    Enum.reduce_while(models, {:ok, MapSet.new()}, fn model, {:ok, seen} ->
      cond do
        not valid_model?(model) ->
          {:halt, {:error, {:invalid_model_id, adapter_id, model}}}

        MapSet.member?(seen, model) ->
          {:halt, {:error, {:duplicate_model_id, adapter_id, model}}}

        true ->
          {:cont, {:ok, MapSet.put(seen, model)}}
      end
    end)
    |> case do
      {:ok, _seen} -> {:ok, models}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_models(models, adapter_id),
    do: {:error, {:invalid_models, adapter_id, models}}

  defp valid_model?(model),
    do: is_binary(model) and model != "" and model == String.trim(model)

  defp ensure_model(models, adapter_id, model) do
    if model in models,
      do: :ok,
      else: {:error, {:unknown_model, "#{adapter_id}/#{model}"}}
  end
end
