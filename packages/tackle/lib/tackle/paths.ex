defmodule Tackle.Paths do
  @moduledoc """
  Resolves the harness-owned configuration and authentication paths.

  `TACKLE_HOME` overrides the default `~/.tackle` directory. Resolution returns
  explicit errors rather than guessing when the operating-system user home is
  unavailable.
  """

  @type resolve_option ::
          {:env, %{optional(String.t()) => String.t()}}
          | {:user_home, String.t() | nil}

  @doc "Resolves the Tackle home directory."
  @spec home([resolve_option()]) :: {:ok, Path.t()} | {:error, :user_home_unavailable}
  def home(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    case Map.get(env, "TACKLE_HOME") do
      value when is_binary(value) and value != "" ->
        {:ok, Path.expand(value)}

      _ ->
        case Keyword.get_lazy(opts, :user_home, &System.user_home/0) do
          value when is_binary(value) and value != "" ->
            {:ok, Path.join(value, ".tackle") |> Path.expand()}

          _ ->
            {:error, :user_home_unavailable}
        end
    end
  end

  @doc """
  Resolves the user-level `~/.agents` directory used by the Agent Skills standard.

  The directory is independent of `TACKLE_HOME`; `:user_home` overrides the
  operating-system home so callers and tests can stay hermetic.
  """
  @spec agents_dir([resolve_option()]) :: {:ok, Path.t()} | {:error, :user_home_unavailable}
  def agents_dir(opts \\ []) do
    case Keyword.get_lazy(opts, :user_home, &System.user_home/0) do
      value when is_binary(value) and value != "" ->
        {:ok, Path.join(value, ".agents") |> Path.expand()}

      _ ->
        {:error, :user_home_unavailable}
    end
  end

  @doc """
  Encodes a directory path as one path component that names its project.

  The path is expanded, its leading `/` dropped, every `-` escaped as `-2D`,
  and every `/` replaced by `-`; the result is enclosed in `--`, so
  `/home/user/project` becomes `--home-user-project--`. Escaping keeps
  `/a-b` and `/a/b` apart, and the enclosing dashes keep keys apart from
  other directory names. Session storage keys project sessions by working
  directory this way, and code review history keys by repository root.

      iex> Tackle.Paths.project_key("/home/user/my-project")
      "--home-user-my-2Dproject--"
  """
  @spec project_key(Path.t()) :: String.t()
  def project_key(path) when is_binary(path) do
    encoded =
      path
      |> Path.expand()
      |> String.trim_leading("/")
      |> String.replace("-", "-2D")
      |> String.replace("/", "-")

    "--" <> encoded <> "--"
  end

  @doc "Resolves `$TACKLE_HOME/config.json`."
  @spec config_file([resolve_option()]) :: {:ok, Path.t()} | {:error, :user_home_unavailable}
  def config_file(opts \\ []) do
    with {:ok, home} <- home(opts), do: {:ok, Path.join(home, "config.json")}
  end

  @doc "Resolves `$TACKLE_HOME/auth.json`."
  @spec auth_file([resolve_option()]) :: {:ok, Path.t()} | {:error, :user_home_unavailable}
  def auth_file(opts \\ []) do
    with {:ok, home} <- home(opts), do: {:ok, Path.join(home, "auth.json")}
  end
end
