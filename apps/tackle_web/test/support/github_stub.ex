defmodule Tackle.Web.GitHubStub do
  @moduledoc """
  A stand-in for `api.github.com`, backed by a real HTTP listener.

  Pull request tests run the real client, the real clone and the real diff, and
  replace only GitHub's API. Pointing `:github_api_url` at this listener keeps
  the whole flow — request, headers, JSON decoding, error mapping — under test
  without reaching the network.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Starts a listener that answers every request with `response`, and points
  `:github_api_url` at it for the duration of the test.

  `response` is either `{status, body}` or a body, which is answered with 200.
  """
  @spec start({non_neg_integer(), String.t()} | String.t()) :: String.t()
  def start(response) do
    {:ok, server} = Bandit.start_link(plug: {__MODULE__, response}, port: 0)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous = Application.get_env(:tackle_web, :github_api_url)
    Application.put_env(:tackle_web, :github_api_url, "http://127.0.0.1:#{port}")

    ExUnit.Callbacks.on_exit(fn ->
      restore(previous)
      stop(server)
    end)

    "http://127.0.0.1:#{port}"
  end

  # The listener is linked to the test process and so is usually already gone by
  # the time the test's `on_exit` callbacks run.
  defp stop(server) do
    Supervisor.stop(server)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Encodes a pull request payload the way GitHub's API would.
  """
  @spec pull_payload(map()) :: String.t()
  def pull_payload(overrides \\ %{}) do
    %{
      "number" => 7,
      "title" => "Teach the widget to spin",
      "body" => "It only wobbled before.",
      "state" => "open",
      "draft" => false,
      "html_url" => "https://example.test/acme/widgets/pull/7",
      "additions" => 1,
      "deletions" => 0,
      "changed_files" => 1,
      "user" => %{"login" => "contributor"},
      "base" => %{"ref" => "main", "sha" => "basesha"},
      "head" => %{"ref" => "feature", "sha" => "headsha"}
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end

  @impl true
  def init(response), do: response

  @impl true
  def call(conn, {status, body}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  def call(conn, body) when is_binary(body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp restore(nil), do: Application.delete_env(:tackle_web, :github_api_url)
  defp restore(value), do: Application.put_env(:tackle_web, :github_api_url, value)
end
