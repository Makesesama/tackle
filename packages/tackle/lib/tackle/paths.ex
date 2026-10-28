defmodule Tackle.Paths do
  @moduledoc """
  Resolves the harness-owned directories and files: the Tackle home with
  `config.json` and `auth.json`, the user's home directory and its
  `~/.agents`, and the project keys of session storage and review history.

  `TACKLE_HOME` overrides the default `~/.tackle` directory. Resolution returns
  explicit errors rather than guessing when the operating-system user home is
  unavailable. `homes/1` resolves both homes once, so everything discovered
  for one session uses the same environment.
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
  Resolves the user's home directory, or `nil` when there is none.

  `:user_home` wins when given, even as `nil`; otherwise `HOME` (or
  `USERPROFILE`) from `:env` when an environment is given; otherwise the
  operating-system home.
  """
  @spec user_home([resolve_option()]) :: Path.t() | nil
  def user_home(opts \\ []) do
    home =
      case {Keyword.fetch(opts, :user_home), Keyword.fetch(opts, :env)} do
        {{:ok, home}, _env} -> home
        {:error, {:ok, env}} -> Map.get(env, "HOME") || Map.get(env, "USERPROFILE")
        {:error, :error} -> System.user_home()
      end

    if is_binary(home) and home != "", do: Path.expand(home)
  end

  @typedoc """
  The Tackle home (`nil` when it cannot be resolved) and the user's home
  directory (`nil` for none), resolved once, as the `:home` and `:user_home`
  options that project discovery (`Tackle.Agents.discover/1`,
  `Tackle.Workflows`, `Tackle.LocalReview.Rules.discover/1`) takes.
  """
  @type homes :: [home: Path.t() | nil, user_home: Path.t() | nil]

  @doc """
  Resolves the Tackle home and the user's home directory together, keeping
  those given as `:home` and `:user_home` (`nil` for none) and resolving the
  others as `home/1` and `user_home/1` do from the same options, so
  everything discovered for one session uses one environment.
  """
  @spec homes([resolve_option() | {:home, Path.t() | nil}]) :: homes()
  def homes(opts \\ []) do
    home =
      case Keyword.fetch(opts, :home) do
        {:ok, home} -> home && Path.expand(home)
        :error -> opts |> home() |> ok_or_nil()
      end

    [home: home, user_home: user_home(opts)]
  end

  defp ok_or_nil({:ok, path}), do: path
  defp ok_or_nil({:error, :user_home_unavailable}), do: nil

  @doc """
  Resolves the user-level `~/.agents` directory used by the Agent Skills standard.

  The directory is independent of `TACKLE_HOME`; the home directory is
  `user_home/1`'s, so callers and tests can stay hermetic.
  """
  @spec agents_dir([resolve_option()]) :: {:ok, Path.t()} | {:error, :user_home_unavailable}
  def agents_dir(opts \\ []) do
    case user_home(opts) do
      nil -> {:error, :user_home_unavailable}
      home -> {:ok, Path.join(home, ".agents")}
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
