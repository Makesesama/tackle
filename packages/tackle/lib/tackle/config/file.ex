defmodule Tackle.Config.File do
  @moduledoc false

  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Thinking
  alias Tackle.Review.Settings, as: ReviewSettings

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
    "agents",
    "compile_gate",
    "jail"
  ]

  # A project file comes from the repository, so it may only choose among what
  # the user already configured: it cannot declare providers (which carry base
  # URLs and credential settings), and the CLI-only display preference stays
  # with the user. Nor can it name host environment variables to pass into the
  # jail (`jail`), which would hand a cloned repository the user's secrets.
  @project_fields @known_fields -- ["providers", "show_subagent_sidebar", "jail"]

  @doc "Loads the user configuration file; a missing file is empty."
  @spec load(Path.t()) :: {:ok, keyword()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, config} <- read_user(path), do: to_options(path, config)
  end

  @doc """
  Loads the user configuration file layered under a project file's contents.

  The project file may use every field except `providers`,
  `show_subagent_sidebar`, and `jail`. Each file is validated on its own; then JSON objects
  merge recursively, with project values replacing user values, except that a
  project cannot turn on a compile gate the user did not turn on. In either
  file, `null` leaves a field or object member unset: a project's `null`
  removes the user's value.

  Returns the merged options and each file's own options, user file first, so
  that a caller can name the file that set an invalid value.
  """
  @spec load(Path.t(), {Path.t(), binary()} | nil) ::
          {:ok, keyword(), [{Path.t(), keyword()}]} | {:error, term()}
  def load(user_path, nil) do
    with {:ok, opts} <- load(user_path), do: {:ok, opts, [{user_path, opts}]}
  end

  def load(user_path, {project_path, contents}) when is_binary(user_path) do
    with {:ok, user} <- read_user(user_path),
         {:ok, user_opts} <- to_options(user_path, user),
         {:ok, project} <- decode(project_path, contents, @project_fields),
         {:ok, project_opts} <- to_options(project_path, drop_nulls(project)),
         merged = user |> deep_merge(project) |> drop_nulls() |> keep_compile_gate_opt_in(user),
         {:ok, opts} <- to_options(project_path, merged) do
      {:ok, opts, [{user_path, user_opts}, {project_path, project_opts}]}
    end
  end

  # A project file may tune or turn off the compile gate, which runs
  # `mix compile` on the project, but only the user can turn it on.
  defp keep_compile_gate_opt_in(merged, user) do
    if compile_gate_on?(Map.get(user, "compile_gate")),
      do: merged,
      else: Map.delete(merged, "compile_gate")
  end

  defp compile_gate_on?(%{"enabled" => false}), do: false
  defp compile_gate_on?(%{}), do: true
  defp compile_gate_on?(_off), do: false

  defp read_user(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, config} <- decode(path, contents, @known_fields), do: {:ok, drop_nulls(config)}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:config_file, path, {:unreadable, reason}}}
    end
  end

  defp decode(path, contents, known_fields) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> validate_fields(path, normalize_switches(config), known_fields)
      {:ok, _other} -> {:error, {:config_file, path, :expected_object}}
      {:error, _reason} -> {:error, {:config_file, path, :malformed}}
    end
  end

  defp validate_fields(path, config, known_fields) do
    case Map.keys(config) -- known_fields do
      [] -> {:ok, config}
      fields -> {:error, {:config_file, path, {:unknown_fields, Enum.sort(fields)}}}
    end
  end

  # `null` leaves a field unset, at any depth of objects; arrays are values.
  defp drop_nulls(%{} = object),
    do: for({key, value} <- object, value != nil, into: %{}, do: {key, drop_nulls(value)})

  defp drop_nulls(value), do: value

  defp deep_merge(%{} = base, %{} = override),
    do: Map.merge(base, override, fn _key, left, right -> deep_merge(left, right) end)

  defp deep_merge(_base, override), do: override

  defp to_options(path, config) do
    with {:ok, model_opts} <- model_options(path, config),
         {:ok, thinking_opts} <- thinking_options(path, config),
         {:ok, provider_opts} <- providers_options(path, config),
         {:ok, switch_opts} <- switch_options(path, config),
         {:ok, decision_opts} <- decision_model_options(path, config),
         {:ok, review_opts} <- review_options(path, config),
         {:ok, agent_opts} <- agents_options(path, config),
         :ok <- sidebar_option(path, config),
         :ok <- jail_option(path, config) do
      {:ok,
       model_opts ++
         thinking_opts ++
         provider_opts ++ switch_opts ++ decision_opts ++ review_opts ++ agent_opts}
    end
  end

  # The features a file switches on and off. Each field takes an object of
  # the listed members, `true` (the same as `{"enabled": true}`), or `false`
  # (`{"enabled": false}`), and becomes a keyword list under the named option;
  # the values are validated by the option's module:
  #
  #   * `compile_gate` - `Tackle.Elixir.CompileGate.Settings`, off by default.
  #     The log path is not a file setting; `Tackle.Config.load/1` puts the
  #     log under the Tackle home.
  #   * `session_titles` - `Tackle.Config.SessionTitles`, on by default in
  #     `Tackle.Config.load/1`.
  #   * `watchdog` - `Tackle.Config.Watchdog`, off by default.
  #   * `narration` - `Tackle.Config.Narration`, off by default.
  @switches %{
    "compile_gate" =>
      {:compile_gate,
       %{
         "enabled" => :enabled,
         "max_rounds" => :max_rounds,
         "timeout_seconds" => :timeout_seconds,
         "warnings" => :warnings
       }},
    "session_titles" => {:session_titles, %{"enabled" => :enabled, "model" => :model}},
    "watchdog" =>
      {:watchdog,
       %{
         "enabled" => :enabled,
         "model" => :model,
         "after_seconds" => :after_seconds,
         "threshold" => :threshold
       }},
    "narration" =>
      {:narration,
       %{
         "enabled" => :enabled,
         "model" => :model,
         "interval_seconds" => :interval_seconds,
         "first_after_seconds" => :first_after_seconds
       }}
  }

  defp normalize_switches(config) do
    Enum.reduce(Map.keys(@switches), config, fn field, config ->
      case Map.fetch(config, field) do
        {:ok, enabled} when is_boolean(enabled) ->
          Map.put(config, field, %{"enabled" => enabled})

        _object_or_absent ->
          config
      end
    end)
  end

  defp switch_options(path, config) do
    Enum.reduce_while(@switches, {:ok, []}, fn {field, {option, members}}, {:ok, acc} ->
      case object_options(Map.get(config, field), members) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, opts} -> {:cont, {:ok, [{option, opts} | acc]}}
        :error -> {:halt, {:error, {:config_file, path, {:invalid_field, field}}}}
      end
    end)
  end

  # An object whose members are all listed becomes a keyword list of their
  # option names; a missing field is `nil`.
  defp object_options(nil, _members), do: {:ok, nil}

  defp object_options(%{} = object, members) do
    if Map.keys(object) -- Map.keys(members) == [],
      do: {:ok, Enum.map(object, fn {key, value} -> {Map.fetch!(members, key), value} end)},
      else: :error
  end

  defp object_options(_other, _members), do: :error

  # Per-profile subagent settings keyed by profile name: each entry may set
  # `model` (canonical model reference) and `thinking`. Names are kept as
  # strings; values are validated by `Tackle.Config`.
  @agent_members %{"model" => :model, "thinking" => :thinking}

  defp agents_options(path, config) do
    case Map.fetch(config, "agents") do
      {:ok, %{} = agents} -> agents_entries(path, agents)
      {:ok, _other} -> {:error, {:config_file, path, {:invalid_field, "agents"}}}
      :error -> {:ok, []}
    end
  end

  defp agents_entries(path, agents) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case agent_settings(entry) do
        {:ok, settings} -> {:cont, {:ok, Map.put(acc, name, settings)}}
        :error -> {:halt, {:error, {:config_file, path, {:invalid_agent, name}}}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, [agents: agents]}
      error -> error
    end
  end

  defp agent_settings(entry) do
    case object_options(entry, @agent_members) do
      {:ok, settings} when is_list(settings) -> {:ok, Map.new(settings)}
      _invalid -> :error
    end
  end

  # Code review defaults: parsed and validated by `Tackle.Review.Settings`,
  # so every host accepts the same `review` object.
  defp review_options(path, config) do
    case Map.fetch(config, "review") do
      {:ok, review} ->
        case ReviewSettings.from_json(review) do
          {:ok, opts} -> {:ok, [review: opts]}
          :error -> {:error, {:config_file, path, {:invalid_field, "review"}}}
        end

      :error ->
        {:ok, []}
    end
  end

  # Configured provider instances, keyed by provider id. Each entry names an
  # adapter type id under `"adapter"`; every other key is an opaque setting the
  # adapter interprets. Adapter types are checked when providers are merged
  # (`Tackle.Plugins.merge_providers/3`), since only the host knows them.
  defp providers_options(path, config) do
    case Map.fetch(config, "providers") do
      {:ok, %{} = providers} -> validate_providers(path, providers)
      {:ok, _other} -> {:error, {:config_file, path, {:invalid_field, "providers"}}}
      :error -> {:ok, []}
    end
  end

  defp validate_providers(path, providers) do
    case Enum.find(providers, &(not valid_provider_entry?(&1))) do
      nil -> {:ok, [providers: providers]}
      {id, _entry} -> {:error, {:config_file, path, {:invalid_provider, id}}}
    end
  end

  defp valid_provider_entry?({id, %{"adapter" => adapter}}),
    do: Provider.valid_id?(id) and Provider.valid_id?(adapter)

  defp valid_provider_entry?(_entry), do: false

  defp sidebar_option(path, config) do
    case Map.fetch(config, "show_subagent_sidebar") do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, {:config_file, path, {:invalid_field, "show_subagent_sidebar"}}}
      :error -> :ok
    end
  end

  @doc """
  Returns the host environment variables the user file passes into a jail:
  the names in `jail.env`, or `[]`. The whole file is validated; a missing
  file is empty. Only the user file can set them.
  """
  @spec jail_env(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def jail_env(path) when is_binary(path) do
    with {:ok, config} <- read_user(path),
         {:ok, _opts} <- to_options(path, config) do
      case config do
        %{"jail" => %{"env" => names}} -> {:ok, names}
        _other -> {:ok, []}
      end
    end
  end

  # The CLI's jail settings. Like the sidebar preference, they are validated
  # here but are not session options: `Tackle.CLI.Jail` reads them with
  # `jail_env/1`.
  defp jail_option(path, config) do
    case Map.fetch(config, "jail") do
      {:ok, %{} = jail} -> jail_fields(path, jail)
      {:ok, _other} -> {:error, {:config_file, path, {:invalid_field, "jail"}}}
      :error -> :ok
    end
  end

  defp jail_fields(path, %{"env" => names} = jail) when map_size(jail) == 1 and is_list(names) do
    if Enum.all?(names, &env_name?/1),
      do: :ok,
      else: {:error, {:config_file, path, {:invalid_field, "jail"}}}
  end

  defp jail_fields(_path, jail) when map_size(jail) == 0, do: :ok
  defp jail_fields(path, _jail), do: {:error, {:config_file, path, {:invalid_field, "jail"}}}

  defp env_name?(name), do: is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name)

  # The default decision model for classification (`tackle.classify` in
  # workflows); `Tackle.Config` resolves it against the session's adapters.
  defp decision_model_options(path, config) do
    case Map.fetch(config, "decision_model") do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, [decision_model: model]}
      {:ok, _model} -> {:error, {:config_file, path, {:invalid_field, "decision_model"}}}
      :error -> {:ok, []}
    end
  end

  defp model_options(path, config) do
    case Map.fetch(config, "model") do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, [model: model]}
      {:ok, _model} -> {:error, {:config_file, path, {:invalid_field, "model"}}}
      :error -> {:ok, []}
    end
  end

  defp thinking_options(path, config) do
    case Map.fetch(config, "thinking") do
      {:ok, level} ->
        case Thinking.validate(level) do
          :ok -> {:ok, [thinking: level]}
          {:error, _reason} -> {:error, {:config_file, path, {:invalid_field, "thinking"}}}
        end

      :error ->
        {:ok, []}
    end
  end
end
