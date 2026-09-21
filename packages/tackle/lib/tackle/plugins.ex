defmodule Tackle.Plugins do
  @moduledoc """
  Resolves harness-owned plugin contributions made available to frontends.

  This initial slice supports adapter modules that are already available in the
  running BEAM and configured by trusted application code. CLI arguments and
  user configuration select model references; they do not name or load adapter
  modules directly.
  """

  alias Tackle.Lib.LLM

  @adapter_id_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @doc "Returns configured adapter modules after validating their public contract."
  @spec available_adapters(keyword()) :: {:ok, [module()]} | {:error, term()}
  def available_adapters(opts \\ [])

  def available_adapters(opts) when is_list(opts) do
    opts
    |> Keyword.get_lazy(:adapters, fn -> Application.get_env(:tackle, :adapters, []) end)
    |> validate_adapters()
  end

  def available_adapters(opts), do: {:error, {:invalid_plugin_options, opts}}

  @doc "Returns canonical model references exposed by the configured adapters."
  @spec available_model_refs(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def available_model_refs(opts \\ []) do
    with {:ok, adapters} <- available_adapters(opts) do
      model_refs(adapters)
    end
  end

  @doc "Returns the first canonical model reference for configured adapters."
  @spec default_model_ref([module()]) :: {:ok, String.t()} | {:error, term()}
  def default_model_ref(adapters) when is_list(adapters) and adapters != [] do
    with {:ok, refs} <- model_refs(adapters), do: {:ok, hd(refs)}
  end

  def default_model_ref([]), do: {:error, :no_adapters_configured}
  def default_model_ref(adapters), do: {:error, {:invalid_adapters_configuration, adapters}}

  defp validate_adapters(adapters) when is_list(adapters) and adapters != [] do
    case first_model_ref(adapters) do
      {:ok, model_ref} ->
        case LLM.select(adapters, model_ref) do
          {:ok, _selection} -> {:ok, adapters}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_adapters([]), do: {:error, :no_adapters_configured}
  defp validate_adapters(adapters), do: {:error, {:invalid_adapters_configuration, adapters}}

  defp first_model_ref(adapters) do
    Enum.find_value(adapters, fn adapter ->
      with {:ok, adapter_id} <- adapter_value(adapter, :adapter_id),
           {:ok, [model | _models]} <- adapter_value(adapter, :models) do
        {:ok, "#{adapter_id}/#{model}"}
      else
        _reason -> nil
      end
    end) || {:error, :no_models_configured}
  end

  defp model_refs(adapters) do
    adapters
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn adapter, {:ok, seen_ids, refs} ->
      with {:ok, adapter_id} <- adapter_value(adapter, :adapter_id),
           :ok <- validate_adapter_id(adapter_id),
           :ok <- unique_adapter_id(adapter_id, seen_ids),
           {:ok, models} <- adapter_value(adapter, :models),
           {:ok, model_refs} <- validate_models(adapter_id, models) do
        {:cont, {:ok, MapSet.put(seen_ids, adapter_id), refs ++ model_refs}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen_ids, refs} when refs != [] -> {:ok, refs}
      {:ok, _seen_ids, []} -> {:error, :no_models_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_value(adapter, callback) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, 0) do
      {:ok, apply(adapter, callback, [])}
    else
      {:error, {:invalid_adapter, adapter, {:missing_callback, {callback, 0}}}}
    end
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end

  defp validate_adapter_id(adapter_id) do
    if is_binary(adapter_id) and Regex.match?(@adapter_id_pattern, adapter_id),
      do: :ok,
      else: {:error, {:invalid_adapter_id, adapter_id}}
  end

  defp unique_adapter_id(adapter_id, seen_ids) do
    if MapSet.member?(seen_ids, adapter_id),
      do: {:error, {:duplicate_adapter_id, adapter_id}},
      else: :ok
  end

  defp validate_models(adapter_id, models) when is_list(models) do
    models
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn model, {:ok, seen_models, refs} ->
      cond do
        not valid_model?(model) ->
          {:halt, {:error, {:invalid_model_id, adapter_id, model}}}

        MapSet.member?(seen_models, model) ->
          {:halt, {:error, {:duplicate_model_id, adapter_id, model}}}

        true ->
          {:cont, {:ok, MapSet.put(seen_models, model), ["#{adapter_id}/#{model}" | refs]}}
      end
    end)
    |> case do
      {:ok, _seen_models, refs} -> {:ok, Enum.reverse(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_models(adapter_id, models), do: {:error, {:invalid_models, adapter_id, models}}

  defp valid_model?(model), do: is_binary(model) and model != "" and model == String.trim(model)
end
