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
      {:ok, Map.get(config, "show_subagent_sidebar", true)}
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

  defp read(path) do
    with :ok <- safe_target(path),
         {:ok, _opts} <- ConfigFile.load(path) do
      case File.read(path) do
        {:ok, json} -> JSON.decode(json)
        {:error, :enoent} -> {:ok, %{}}
        {:error, reason} -> {:error, {:config_file_unreadable, path, reason}}
      end
    end
  end

  defp safe_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, {:config_file_unreadable, path, :unsafe_target}}
      {:error, reason} -> {:error, {:config_file_unreadable, path, reason}}
    end
  end
end
