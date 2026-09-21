defmodule Tackle.Web.Paths do
  @moduledoc """
  Resolves the runtime data directories used by the web frontend.

  Runtime data — cloned repositories and Lumis language artifacts — is never
  kept inside the source tree. This module is the single place that decides
  where it goes, so every caller agrees and every path stays overridable.

  Each path is resolved with this precedence:

    1. an environment variable (`TACKLE_WEB_DATA_ROOT`, `TACKLE_WEB_REPOS_ROOT`,
       `TACKLE_WEB_LUMIS_DATA_DIR`)
    2. explicit application configuration (`config :tackle_web, ...`)
    3. a default derived from `data_root/0`

  The environment variable wins over application config on purpose: it is the
  operator's escape hatch and has to work even when a value is baked into
  `config/config.exs`.

  `repos_root/0` and `lumis_data_dir/0` are resolved independently, so a
  deployment can put clones on a large volume while keeping Lumis artifacts on
  local disk.

  ## Configuration

      config :tackle_web, repos_root: "/mnt/big/tackle_web/repos"

  The last-resort data root defaults to `/var/tackle_web`. That location is not
  writable by an unprivileged user on a fresh machine, which is deliberate:
  `ensure_dir!/1` fails with the exact command needed to fix it rather than
  silently scattering gigabytes somewhere unexpected. For a development
  checkout, point `TACKLE_WEB_DATA_ROOT` at a user-writable directory instead.
  """

  @default_data_root "/var/tackle_web"

  @env_data_root "TACKLE_WEB_DATA_ROOT"
  @env_repos_root "TACKLE_WEB_REPOS_ROOT"
  @env_lumis_data_dir "TACKLE_WEB_LUMIS_DATA_DIR"
  @env_reviews_root "TACKLE_WEB_REVIEWS_ROOT"
  @env_conversations_root "TACKLE_WEB_CONVERSATIONS_ROOT"

  @doc """
  Root under which the other paths are derived by default.

  Overridable via `TACKLE_WEB_DATA_ROOT` or `config :tackle_web, :data_root`.
  """
  @spec data_root() :: Path.t()
  def data_root do
    env(@env_data_root) || config(:data_root) || @default_data_root
  end

  @doc """
  Directory holding the repository checkouts, one subdirectory per `owner/name`.

  Overridable via `TACKLE_WEB_REPOS_ROOT` or `config :tackle_web, :repos_root`.
  """
  @spec repos_root() :: Path.t()
  def repos_root do
    env(@env_repos_root) || config(:repos_root) || Path.join(data_root(), "repos")
  end

  @doc """
  Directory Lumis stores its compiled language parsers in.

  Overridable via `TACKLE_WEB_LUMIS_DATA_DIR` or
  `config :tackle_web, :lumis_data_dir`. Assigned to Lumis from
  `config/runtime.exs`, because Lumis reads it at boot rather than per call.
  """
  @spec lumis_data_dir() :: Path.t()
  def lumis_data_dir do
    env(@env_lumis_data_dir) || config(:lumis_data_dir) || Path.join(data_root(), "lumis")
  end

  @doc """
  Directory holding the review state (comments and viewed markers).

  Overridable via `TACKLE_WEB_REVIEWS_ROOT` or `config :tackle_web, :reviews_root`.
  """
  @spec reviews_root() :: Path.t()
  def reviews_root do
    env(@env_reviews_root) || config(:reviews_root) || Path.join(data_root(), "reviews")
  end

  @doc """
  Directory holding the assistant conversations kept per pull request.

  Overridable via `TACKLE_WEB_CONVERSATIONS_ROOT` or
  `config :tackle_web, :conversations_root`.
  """
  @spec conversations_root() :: Path.t()
  def conversations_root do
    env(@env_conversations_root) || config(:conversations_root) ||
      Path.join(data_root(), "conversations")
  end

  @doc """
  Absolute path of the checkout used to review `owner/name`.

  The path is derived from `repos_root/0` and says nothing about whether the
  checkout exists yet; use `ensure_dir!/1` before writing to it.
  """
  @spec repo_path(String.t(), String.t()) :: Path.t()
  def repo_path(owner, name) when is_binary(owner) and is_binary(name) do
    Path.join([repos_root(), owner, name])
  end

  @doc """
  Absolute path of the checkout holding one pull request.

  One clone per pull request rather than per repository, so the assistant can be
  given a working tree checked out at that pull request's head without two
  reviews of the same repository fighting over a single work tree.
  """
  @spec pull_request_path(String.t(), String.t(), pos_integer()) :: Path.t()
  def pull_request_path(owner, name, number)
      when is_binary(owner) and is_binary(name) and is_integer(number) do
    Path.join([repos_root(), owner, name, "pr-#{number}"])
  end

  @doc """
  Ensures `path` exists as a directory, returning it.

  Raises with the failure reason and the command needed to make the default data
  root writable, rather than letting a downstream call fail with a bare `:enoent`.
  """
  @spec ensure_dir!(Path.t()) :: Path.t()
  def ensure_dir!(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> path
      {:error, reason} -> raise mkdir_error(path, reason)
    end
  end

  defp mkdir_error(path, reason) do
    """
    Could not create the runtime data directory:

        #{path}

    Reason: #{:file.format_error(reason)}

    Point the runtime data somewhere writable, either for this shell:

        export TACKLE_WEB_DATA_ROOT=/some/writable/directory

    or persistently in config/config.exs:

        config :tackle_web, data_root: "/some/writable/directory"

    To keep the default location instead, create it once:

        sudo mkdir -p #{path} && sudo chown -R "$(id -u):$(id -g)" #{@default_data_root}
    """
  end

  defp env(name), do: blank_to_nil(System.get_env(name))

  defp config(key), do: blank_to_nil(Application.get_env(:tackle_web, key))

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
