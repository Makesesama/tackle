defmodule Tackle.Web.GitHub do
  @moduledoc """
  Minimal GitHub REST client for pull request metadata.

  Only metadata is read from the API. The diff itself is computed locally from a
  clone, because GitHub's `position` fields are hunk offsets rather than line
  numbers and go stale as soon as the pull request head moves.

  ## Authentication

  A token is resolved in this order, first match wins:

    1. `config :tackle_web, :github_token`
    2. `GITHUB_TOKEN`, then `GH_TOKEN`
    3. the local `gh` CLI (`gh auth token`)

  Anonymous access works for public repositories. A token is needed to see
  private ones, and it raises the rate limit. Responses are decoded with
  Elixir's standard-library `JSON` module — the project does not depend on a
  third-party JSON library.
  """

  @default_api_url "https://api.github.com"
  @default_host "https://github.com"
  @accept "application/vnd.github+json"
  @api_version "2022-11-28"
  @timeout 20_000

  # `https://github.com/owner/repo/pull/123`, `owner/repo#123` and
  # `owner/repo/pull/123` all name the same pull request.
  @reference ~r{^(?:https?://github\.com/)?(?<owner>[^/\s]+)/(?<repo>[^/\s#]+?)(?:/pull/|#)(?<number>\d+)/?$}

  @type pull_reference :: {owner :: String.t(), name :: String.t(), number :: pos_integer()}

  @type pull :: %{
          owner: String.t(),
          name: String.t(),
          number: pos_integer(),
          title: String.t(),
          body: String.t(),
          state: String.t(),
          draft: boolean(),
          author: String.t() | nil,
          html_url: String.t() | nil,
          base_ref: String.t(),
          base_sha: String.t(),
          head_ref: String.t(),
          head_sha: String.t(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          changed_files: non_neg_integer(),
          clone_url: String.t()
        }

  @doc """
  Parses a pull request reference typed into the UI.

  Accepts a full `https://github.com/owner/repo/pull/123` URL, the short
  `owner/repo#123` form, or `owner/repo/pull/123`.
  """
  @spec parse(String.t()) :: {:ok, pull_reference()} | {:error, String.t()}
  def parse(input) do
    case Regex.named_captures(@reference, String.trim(to_string(input))) do
      %{"owner" => owner, "repo" => name, "number" => number} ->
        {:ok, {owner, name, String.to_integer(number)}}

      nil ->
        {:error,
         "Expected a pull request like https://github.com/owner/repo/pull/123 or owner/repo#123"}
    end
  end

  @doc """
  Fetches the metadata of a pull request.
  """
  @spec pull(String.t(), String.t(), pos_integer()) :: {:ok, pull()} | {:error, String.t()}
  def pull(owner, name, number) do
    with {:ok, body} <- get("/repos/#{owner}/#{name}/pulls/#{number}"),
         true <- is_map(body) do
      {:ok, from_api(body, owner, name)}
    else
      false -> {:error, "GitHub returned an unexpected response body."}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Maps a GitHub pull request payload onto the fields the review UI uses.

  Kept separate from the HTTP call so the mapping can be exercised against
  recorded payloads.
  """
  @spec from_api(map(), String.t(), String.t()) :: pull()
  def from_api(body, owner, name) do
    base = map(body["base"])
    head = map(body["head"])

    %{
      owner: owner,
      name: name,
      number: body["number"],
      title: body["title"] || "",
      body: body["body"] || "",
      state: body["state"] || "unknown",
      draft: body["draft"] == true,
      author: get_in(body, ["user", "login"]),
      html_url: body["html_url"],
      base_ref: base["ref"],
      base_sha: base["sha"],
      head_ref: head["ref"],
      head_sha: head["sha"],
      additions: body["additions"] || 0,
      deletions: body["deletions"] || 0,
      changed_files: body["changed_files"] || 0,
      clone_url: get_in(base, ["repo", "clone_url"]) || clone_url(owner, name)
    }
  end

  @doc """
  Base URL of the GitHub API.

  Defaults to `https://api.github.com`. Point it at a GitHub Enterprise host or
  a test double with `config :tackle_web, :github_api_url`.
  """
  @spec api_url() :: String.t()
  def api_url do
    case Application.get_env(:tackle_web, :github_api_url) do
      url when is_binary(url) and url != "" -> url
      _default -> @default_api_url
    end
  end

  @doc """
  Web host that clone URLs are built from.

  Defaults to `https://github.com`. Point it at a GitHub Enterprise host or a
  local mirror with `config :tackle_web, :github_host`.
  """
  @spec host() :: String.t()
  def host do
    case Application.get_env(:tackle_web, :github_host) do
      host when is_binary(host) and host != "" -> host
      _default -> @default_host
    end
  end

  @doc """
  URL to clone `owner/name` from.
  """
  @spec clone_url(String.t(), String.t()) :: String.t()
  def clone_url(owner, name) do
    "#{String.trim_trailing(host(), "/")}/#{owner}/#{name}.git"
  end

  @doc """
  Resolves a GitHub token, or `:error` when none is configured.
  """
  @spec token() :: {:ok, String.t()} | :error
  def token do
    configured_token() || environment_token() || gh_cli_token() || :error
  end

  @doc """
  Environment entries that let git authenticate against GitHub.

  The token is passed through git's `GIT_CONFIG_*` environment interface rather
  than as a command-line `-c` argument, so it never appears in `ps` output, and
  rather than in the clone URL, so it is never written into `.git/config`.
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    case token() do
      {:ok, token} ->
        [
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
          {"GIT_CONFIG_VALUE_0", "Authorization: Bearer #{token}"}
        ]

      :error ->
        []
    end
  end

  defp get(path) do
    options = [
      base_url: api_url(),
      headers: headers(),
      decode_body: false,
      retry: false,
      receive_timeout: @timeout
    ]

    case Req.get(path, options) do
      {:ok, %Req.Response{status: 200, body: raw}} -> decode(raw)
      {:ok, %Req.Response{status: status, body: raw}} -> {:error, api_error(status, raw)}
      {:error, exception} -> {:error, transport_error(exception)}
    end
  end

  defp decode(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, "GitHub returned a body that is not valid JSON."}
    end
  end

  defp headers do
    base = [
      {"accept", @accept},
      {"x-github-api-version", @api_version},
      {"user-agent", "tackle-web"}
    ]

    case token() do
      {:ok, token} -> [{"authorization", "Bearer #{token}"} | base]
      :error -> base
    end
  end

  defp api_error(404, _raw) do
    "GitHub has no such pull request. Private repositories also need a token."
  end

  defp api_error(401, _raw), do: "GitHub rejected the configured token."

  defp api_error(403, raw) do
    if is_binary(raw) and String.contains?(raw, "rate limit") do
      "GitHub rate limit reached. Configure a token to raise it."
    else
      "GitHub denied access to this pull request."
    end
  end

  defp api_error(status, _raw), do: "GitHub responded with HTTP #{status}."

  defp transport_error(%{__struct__: module} = exception) do
    if module == Req.TransportError do
      "Could not reach GitHub: #{Exception.message(exception)}"
    else
      "Could not reach GitHub: #{inspect(exception)}"
    end
  end

  defp transport_error(reason), do: "Could not reach GitHub: #{inspect(reason)}"

  # The pull request ref lives on the base repository, so that is the clone to
  # use: it works for fork pull requests too, and it keeps working after the
  # contributor deletes their branch.
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp configured_token do
    case Application.get_env(:tackle_web, :github_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _unset -> nil
    end
  end

  defp environment_token do
    case System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _unset -> nil
    end
  end

  defp gh_cli_token do
    with path when is_binary(path) <- System.find_executable("gh"),
         {output, 0} <- System.cmd(path, ["auth", "token"], stderr_to_stdout: true),
         token when token != "" <- String.trim(output) do
      {:ok, token}
    else
      _unavailable -> nil
    end
  end
end
