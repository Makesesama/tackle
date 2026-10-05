defmodule Tackle.Config.File do
  @moduledoc false

  alias Tackle.Thinking

  # The sidebar preference belongs to the CLI; the harness accepts and validates
  # the field without carrying presentation state into a session configuration.
  @known_fields ["model", "thinking", "show_subagent_sidebar", "provider_options"]

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
    with {:ok, model_opts} <- model_options(path, config),
         {:ok, thinking_opts} <- thinking_options(path, config),
         {:ok, provider_opts} <- provider_options(path, config),
         :ok <- sidebar_option(path, config) do
      {:ok, model_opts ++ thinking_opts ++ provider_opts}
    end
  end

  # Adapter-owned settings, keyed by adapter id. The harness only checks the
  # shape; each adapter interprets its own entry.
  defp provider_options(path, config) do
    case Map.fetch(config, "provider_options") do
      {:ok, options} ->
        if adapter_settings?(options),
          do: {:ok, [provider_options: options]},
          else: {:error, {:invalid_config_field, path, "provider_options"}}

      :error ->
        {:ok, []}
    end
  end

  defp adapter_settings?(%{} = options), do: Enum.all?(Map.values(options), &is_map/1)
  defp adapter_settings?(_options), do: false

  defp sidebar_option(path, config) do
    case Map.fetch(config, "show_subagent_sidebar") do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, {:invalid_config_field, path, "show_subagent_sidebar"}}
      :error -> :ok
    end
  end

  defp model_options(path, config) do
    case Map.fetch(config, "model") do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, [model: model]}
      {:ok, _model} -> {:error, {:invalid_config_field, path, "model"}}
      :error -> {:ok, []}
    end
  end

  defp thinking_options(path, config) do
    case Map.fetch(config, "thinking") do
      {:ok, level} ->
        case Thinking.validate(level) do
          :ok -> {:ok, [thinking: level]}
          {:error, _reason} -> {:error, {:invalid_config_field, path, "thinking"}}
        end

      :error ->
        {:ok, []}
    end
  end
end
