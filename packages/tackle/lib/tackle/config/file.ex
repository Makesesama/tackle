defmodule Tackle.Config.File do
  @moduledoc false

  alias Tackle.Thinking

  # The sidebar preference belongs to the CLI; the harness accepts and validates
  # the field without carrying presentation state into a session configuration.
  @known_fields [
    "model",
    "thinking",
    "show_subagent_sidebar",
    "provider_options",
    "session_titles"
  ]

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
         {:ok, title_opts} <- session_titles_options(path, config),
         :ok <- sidebar_option(path, config) do
      {:ok, model_opts ++ thinking_opts ++ provider_opts ++ title_opts}
    end
  end

  # LLM-generated session titles: `false` disables them; `true` and `null` mean
  # the default enabled configuration; an object may set `enabled` (boolean,
  # default true) and `model` (canonical model reference for the title call,
  # defaulting to the session model).
  defp session_titles_options(path, config) do
    case Map.fetch(config, "session_titles") do
      {:ok, false} -> {:ok, [session_titles: false]}
      {:ok, true} -> {:ok, [session_titles: []]}
      {:ok, nil} -> {:ok, []}
      {:ok, %{} = titles} -> session_titles_fields(path, titles)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "session_titles"}}
      :error -> {:ok, []}
    end
  end

  defp session_titles_fields(path, titles) do
    case Map.keys(titles) -- ["enabled", "model"] do
      [] ->
        enabled = Map.get(titles, "enabled", true)
        model = Map.get(titles, "model")

        if valid_titles_shape?(enabled, model) do
          {:ok, [session_titles: [enabled: enabled, model: model]]}
        else
          {:error, {:invalid_config_field, path, "session_titles"}}
        end

      _unknown_fields ->
        {:error, {:invalid_config_field, path, "session_titles"}}
    end
  end

  defp valid_titles_shape?(enabled, model) do
    is_boolean(enabled) and (is_nil(model) or (is_binary(model) and model != ""))
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
