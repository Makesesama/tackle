defmodule Tackle.CLI.TUI.Preferences do
  @moduledoc """
  CLI-only display preferences stored alongside harness options in
  `$TACKLE_HOME/config.json`. Updates preserve the other config fields.
  """

  alias Tackle.Config.File, as: ConfigFile

  @doc "Reads the sidebar preference, defaulting to visible when unset."
  @spec sidebar(keyword()) :: {:ok, boolean()} | {:error, term()}
  def sidebar(opts \\ []) do
    with {:ok, path} <- Tackle.Paths.config_file(opts),
         {:ok, config} <- read(path) do
      # `null` leaves the field unset, like in every harness field.
      {:ok, Map.get(config, "show_subagent_sidebar") != false}
    end
  end

  @doc "Persists the sidebar preference without changing harness settings."
  @spec put_sidebar(boolean(), keyword()) :: :ok | {:error, term()}
  def put_sidebar(value, opts \\ []) when is_boolean(value) do
    with {:ok, path} <- Tackle.Paths.config_file(opts),
         {:ok, config} <- read(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- safe_target(path) do
      temp = path <> ".#{System.unique_integer([:positive])}.tmp"

      result =
        with :ok <-
               File.write(temp, JSON.encode!(Map.put(config, "show_subagent_sidebar", value))),
             :ok <- File.chmod(temp, 0o600),
             :ok <- File.rename(temp, path),
             do: :ok

      File.rm(temp)
      result
    end
  end

  # The whole file is validated, and its object is returned as written, so
  # `put_sidebar/2` keeps the other fields unchanged.
  defp read(path) do
    with :ok <- safe_target(path), do: ConfigFile.read(path)
  end

  defp safe_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, {:config_file, path, :unsafe_target}}
      {:error, reason} -> {:error, {:config_file, path, {:unreadable, reason}}}
    end
  end
end
