defmodule Tackle.Config.File do
  @moduledoc false

  @known_fields ["model"]

  @spec load(Path.t()) :: {:ok, keyword()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode(path, contents)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:config_file_unreadable, path, reason}}
    end
  end

  defp decode(path, contents) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> validate_fields(path, config)
      {:ok, _other} -> {:error, {:invalid_config_file, path, :expected_object}}
      {:error, _reason} -> {:error, {:malformed_config_file, path}}
    end
  end

  defp validate_fields(path, config) do
    case Map.keys(config) -- @known_fields do
      [] -> to_options(path, config)
      fields -> {:error, {:unknown_config_fields, path, Enum.sort(fields)}}
    end
  end

  defp to_options(path, config) do
    case Map.fetch(config, "model") do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, [model: model]}
      {:ok, _model} -> {:error, {:invalid_config_field, path, "model"}}
      :error -> {:ok, []}
    end
  end
end
