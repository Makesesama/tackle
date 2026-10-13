defmodule Tackle.Config.File do
  @moduledoc false

  alias Tackle.Lib.LLM.Provider
  alias Tackle.Thinking

  # The sidebar preference belongs to the CLI; the harness accepts and validates
  # the field without carrying presentation state into a session configuration.
  @known_fields [
    "model",
    "thinking",
    "show_subagent_sidebar",
    "providers",
    "session_titles",
    "watchdog",
    "narration",
    "decision_model"
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
         {:ok, provider_opts} <- providers_options(path, config),
         {:ok, title_opts} <- session_titles_options(path, config),
         {:ok, watchdog_opts} <- watchdog_options(path, config),
         {:ok, narration_opts} <- narration_options(path, config),
         {:ok, decision_opts} <- decision_model_options(path, config),
         :ok <- sidebar_option(path, config) do
      {:ok,
       model_opts ++
         thinking_opts ++
         provider_opts ++ title_opts ++ watchdog_opts ++ narration_opts ++ decision_opts}
    end
  end

  # The command watchdog is opt-in because it needs a decision model: `false`
  # and `null` leave it off; an object sets `model` (required canonical decision
  # model reference) and optionally `enabled`, `after_seconds`, and `threshold`.
  # Values are validated by `Tackle.Config.Watchdog`.
  @watchdog_fields %{
    "enabled" => :enabled,
    "model" => :model,
    "after_seconds" => :after_seconds,
    "threshold" => :threshold
  }

  defp watchdog_options(path, config) do
    case Map.fetch(config, "watchdog") do
      {:ok, false} -> {:ok, [watchdog: false]}
      {:ok, nil} -> {:ok, []}
      {:ok, %{} = watchdog} -> watchdog_fields(path, watchdog)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "watchdog"}}
      :error -> {:ok, []}
    end
  end

  defp watchdog_fields(path, watchdog) do
    case Map.keys(watchdog) -- Map.keys(@watchdog_fields) do
      [] ->
        {:ok,
         [watchdog: Enum.map(watchdog, fn {key, value} -> {@watchdog_fields[key], value} end)]}

      _unknown_fields ->
        {:error, {:invalid_config_field, path, "watchdog"}}
    end
  end

  # The narrator is opt-in because it needs a chat model of its own: `false`
  # and `null` leave it off; an object sets `model` (required canonical chat
  # model reference) and optionally `enabled`, `interval_seconds`, and
  # `first_after_seconds`. Values are validated by `Tackle.Config.Narration`.
  @narration_fields %{
    "enabled" => :enabled,
    "model" => :model,
    "interval_seconds" => :interval_seconds,
    "first_after_seconds" => :first_after_seconds
  }

  defp narration_options(path, config) do
    case Map.fetch(config, "narration") do
      {:ok, false} -> {:ok, [narration: false]}
      {:ok, nil} -> {:ok, []}
      {:ok, %{} = narration} -> narration_fields(path, narration)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "narration"}}
      :error -> {:ok, []}
    end
  end

  defp narration_fields(path, narration) do
    case Map.keys(narration) -- Map.keys(@narration_fields) do
      [] ->
        {:ok,
         [
           narration: Enum.map(narration, fn {key, value} -> {@narration_fields[key], value} end)
         ]}

      _unknown_fields ->
        {:error, {:invalid_config_field, path, "narration"}}
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

  # Configured provider instances, keyed by provider id. Each entry names an
  # adapter type id under `"adapter"`; every other key is an opaque setting the
  # adapter interprets. Adapter types are checked when providers are merged
  # (`Tackle.Plugins.merge_providers/3`), since only the host knows them.
  defp providers_options(path, config) do
    case Map.fetch(config, "providers") do
      {:ok, %{} = providers} -> validate_providers(path, providers)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "providers"}}
      :error -> {:ok, []}
    end
  end

  defp validate_providers(path, providers) do
    case Enum.find(providers, &(not valid_provider_entry?(&1))) do
      nil -> {:ok, [providers: providers]}
      {id, _entry} -> {:error, {:invalid_config_provider, path, id}}
    end
  end

  defp valid_provider_entry?({id, %{"adapter" => adapter}}),
    do: Provider.valid_id?(id) and Provider.valid_id?(adapter)

  defp valid_provider_entry?(_entry), do: false

  defp sidebar_option(path, config) do
    case Map.fetch(config, "show_subagent_sidebar") do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, {:invalid_config_field, path, "show_subagent_sidebar"}}
      :error -> :ok
    end
  end

  # The default decision model for classification (`tackle.classify` in
  # workflows); `Tackle.Config` resolves it against the session's adapters.
  defp decision_model_options(path, config) do
    case Map.fetch(config, "decision_model") do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, [decision_model: model]}
      {:ok, nil} -> {:ok, []}
      {:ok, _model} -> {:error, {:invalid_config_field, path, "decision_model"}}
      :error -> {:ok, []}
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
