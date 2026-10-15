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
    "decision_model",
    "review",
    "agents"
  ]

  # A project file comes from the repository, so it may only choose among what
  # the user already configured: it cannot declare providers (which carry base
  # URLs and credential settings), and the CLI-only display preference stays
  # with the user.
  @project_fields @known_fields -- ["providers", "show_subagent_sidebar"]

  @doc "Loads the user configuration file; a missing file is empty."
  @spec load(Path.t()) :: {:ok, keyword()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, config} <- read_user(path), do: to_options(path, config)
  end

  @doc """
  Loads the user configuration file layered under a project file's contents.

  The project file may use every field except `providers` and
  `show_subagent_sidebar`. Each file is validated on its own; then JSON objects
  merge recursively, with project values replacing user values.
  """
  @spec load(Path.t(), {Path.t(), binary()} | nil) :: {:ok, keyword()} | {:error, term()}
  def load(user_path, nil), do: load(user_path)

  def load(user_path, {project_path, contents}) when is_binary(user_path) do
    with {:ok, user} <- read_user(user_path),
         {:ok, _opts} <- to_options(user_path, user),
         {:ok, project} <- decode(project_path, contents, @project_fields),
         {:ok, _opts} <- to_options(project_path, project) do
      to_options(project_path, deep_merge(user, project))
    end
  end

  defp read_user(path) do
    case File.read(path) do
      {:ok, contents} -> decode(path, contents, @known_fields)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:config_file_unreadable, path, reason}}
    end
  end

  defp decode(path, contents, known_fields) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> validate_fields(path, config, known_fields)
      {:ok, _other} -> {:error, {:invalid_config_file, path, :expected_object}}
      {:error, _reason} -> {:error, {:malformed_config_file, path}}
    end
  end

  defp validate_fields(path, config, known_fields) do
    case Map.keys(config) -- known_fields do
      [] -> {:ok, config}
      fields -> {:error, {:unknown_config_fields, path, Enum.sort(fields)}}
    end
  end

  defp deep_merge(%{} = base, %{} = override),
    do: Map.merge(base, override, fn _key, left, right -> deep_merge(left, right) end)

  defp deep_merge(_base, override), do: override

  defp to_options(path, config) do
    with {:ok, model_opts} <- model_options(path, config),
         {:ok, thinking_opts} <- thinking_options(path, config),
         {:ok, provider_opts} <- providers_options(path, config),
         {:ok, title_opts} <- session_titles_options(path, config),
         {:ok, watchdog_opts} <- watchdog_options(path, config),
         {:ok, narration_opts} <- narration_options(path, config),
         {:ok, decision_opts} <- decision_model_options(path, config),
         {:ok, review_opts} <- review_options(path, config),
         {:ok, agent_opts} <- agents_options(path, config),
         :ok <- sidebar_option(path, config) do
      {:ok,
       model_opts ++
         thinking_opts ++
         provider_opts ++
         title_opts ++
         watchdog_opts ++ narration_opts ++ decision_opts ++ review_opts ++ agent_opts}
    end
  end

  # Per-profile subagent settings keyed by profile name: each entry may set
  # `model` (canonical model reference) and `thinking`. Names are kept as
  # strings; values are validated by `Tackle.Config`.
  @agent_fields %{"model" => :model, "thinking" => :thinking}

  defp agents_options(path, config) do
    case Map.fetch(config, "agents") do
      {:ok, nil} -> {:ok, []}
      {:ok, %{} = agents} -> agents_entries(path, agents)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "agents"}}
      :error -> {:ok, []}
    end
  end

  defp agents_entries(path, agents) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case agent_settings(entry) do
        {:ok, settings} -> {:cont, {:ok, Map.put(acc, name, settings)}}
        :error -> {:halt, {:error, {:invalid_config_agent, path, name}}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, [agents: agents]}
      error -> error
    end
  end

  defp agent_settings(%{} = entry) do
    if Map.keys(entry) -- Map.keys(@agent_fields) == [] do
      {:ok, for({key, value} <- entry, value != nil, into: %{}, do: {@agent_fields[key], value})}
    else
      :error
    end
  end

  defp agent_settings(_entry), do: :error

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

  # Code review defaults (`Tackle.Config.Review`): optional `thinking` and
  # `models` objects keyed by the stages `detector`, `verifier`, and `scorer`,
  # a `max_steps` object keyed by `detector` and `verifier`, a `profile`
  # (`quiet`, `default`, or `assertive`), and `default_rules`, a list of
  # built-in rule ids. Names are mapped here so file data never creates atoms;
  # values are validated by `Tackle.Config.Review`.
  @review_stages Map.new(Tackle.Config.Review.stages(), &{Atom.to_string(&1), &1})
  @review_profiles %{"quiet" => :quiet, "default" => :default, "assertive" => :assertive}
  @review_fields ~w(thinking models profile max_steps default_rules)

  defp review_options(path, config) do
    case Map.fetch(config, "review") do
      {:ok, nil} -> {:ok, []}
      {:ok, %{} = review} -> review_fields(path, review)
      {:ok, _other} -> {:error, {:invalid_config_field, path, "review"}}
      :error -> {:ok, []}
    end
  end

  defp review_fields(path, review) do
    with [] <- Map.keys(review) -- @review_fields,
         {:ok, opts} <- review_values(review) do
      {:ok, [review: opts]}
    else
      _invalid -> {:error, {:invalid_config_field, path, "review"}}
    end
  end

  defp review_values(review) do
    Enum.reduce_while(review, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case review_value(key, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp review_value(_key, nil), do: {:ok, nil}

  defp review_value("thinking", %{} = thinking) do
    stage_values(thinking, fn level -> Thinking.validate(level) == :ok end, :thinking)
  end

  defp review_value("models", %{} = models) do
    stage_values(models, &(is_binary(&1) and &1 != ""), :models)
  end

  defp review_value("max_steps", %{} = steps) do
    stage_values(steps, &(is_integer(&1) and &1 > 0), :max_steps)
  end

  defp review_value("profile", profile) do
    case Map.fetch(@review_profiles, profile) do
      {:ok, profile} -> {:ok, {:profile, profile}}
      :error -> :error
    end
  end

  defp review_value("default_rules", ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: {:ok, {:default_rules, ids}}, else: :error
  end

  defp review_value(_key, _value), do: :error

  defp stage_values(values, valid?, key) do
    Enum.reduce_while(values, {:ok, %{}}, fn {stage, value}, {:ok, acc} ->
      with {:ok, stage} <- Map.fetch(@review_stages, stage),
           true <- valid?.(value) do
        {:cont, {:ok, Map.put(acc, stage, value)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, map} -> {:ok, {key, map}}
      :error -> :error
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
