defmodule Tackle.Plugins.MCP.OAuthTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.MCP.OAuth

  test "builds PKCE URL and exchanges validated callback code" do
    parent = self()

    request = fn method, url, _headers, body, _opts ->
      send(parent, {:request, method, url, body})

      cond do
        url == "https://mcp.example/mcp" ->
          {:ok,
           %{
             status: 401,
             headers: [
               {"www-authenticate",
                "Bearer resource_metadata=\"https://mcp.example/.well-known/oauth-protected-resource/mcp\""}
             ],
             body: ""
           }}

        String.ends_with?(url, "/.well-known/oauth-protected-resource/mcp") ->
          {:ok, %{status: 200, body: ~s({"authorization_servers":["https://auth.example"]})}}

        String.ends_with?(url, "/.well-known/oauth-authorization-server") ->
          {:ok,
           %{
             status: 200,
             body:
               ~s({"authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register"})
           }}

        url == "https://auth.example/register" ->
          {:ok, %{status: 201, body: ~s({"client_id":"client"})}}

        url == "https://auth.example/token" ->
          assert body =~ "grant_type=authorization_code"
          assert body =~ "resource=https%3A%2F%2Fmcp.example%2Fmcp"

          {:ok,
           %{
             status: 200,
             body: ~s({"access_token":"secret","token_type":"Bearer","refresh_token":"refresh"})
           }}
      end
    end

    {:ok, flow} =
      OAuth.begin("https://mcp.example/mcp",
        redirect_uri: "http://localhost:1234/callback",
        request: request
      )

    uri = URI.parse(flow.authorization_url)
    query = URI.decode_query(uri.query)
    assert query["code_challenge_method"] == "S256"
    assert query["resource"] == "https://mcp.example/mcp"
    assert query["state"] == flow.state
    assert_receive {:request, :get, _, _}

    assert {:error, :state_mismatch} = OAuth.complete(flow, "wrong", code: "code")
    assert {:ok, credentials} = OAuth.complete(flow, flow.state, code: "code")
    assert credentials.access_token == "secret"
    assert credentials.refresh_token == "refresh"
    assert credentials.client_id == "client"
  end

  test "rejects numeric token type on refresh" do
    request = fn :post, _, _, _, _ ->
      {:ok, %{status: 200, body: ~s({"access_token":"bad","token_type":42})}}
    end

    assert {:error, :invalid_token_response} =
             OAuth.refresh_stored(
               %{
                 "refresh_token" => "old",
                 "token_endpoint" => "https://auth.example/token",
                 "client_id" => "client",
                 "resource" => "https://mcp.example/mcp"
               },
               request: request
             )
  end

  test "refresh preserves a rotated token and includes the resource" do
    request = fn :post, "https://auth.example/token", _, body, _ ->
      assert URI.decode_query(body)["resource"] == "https://mcp.example/mcp"

      {:ok,
       %{status: 200, body: ~s({"access_token":"new","refresh_token":"rotated","expires_in":120})}}
    end

    assert {:ok, fresh} =
             OAuth.refresh_stored(
               %{
                 "refresh_token" => "old",
                 "access_token" => "expired",
                 "token_endpoint" => "https://auth.example/token",
                 "client_id" => "client",
                 "resource" => "https://mcp.example/mcp"
               },
               request: request
             )

    assert fresh["refresh_token"] == "rotated"
    assert fresh["access_token"] == "new"
    assert fresh["expires_at"] > System.system_time(:second)
  end

  test "rejects metadata-directed loopback authorization servers" do
    request = fn _, url, _, _, _ ->
      cond do
        url == "https://mcp.example/mcp" ->
          {:ok, %{status: 200, body: ""}}

        String.contains?(url, "oauth-protected-resource") ->
          {:ok, %{status: 200, body: ~s({"authorization_servers":["http://127.0.0.1:1234"]})}}
      end
    end

    assert {:error, :untrusted_loopback_oauth_server} =
             OAuth.begin("https://mcp.example/mcp",
               redirect_uri: "http://127.0.0.1:3210/callback",
               request: request
             )
  end

  test "rejects insecure resources and redirects" do
    assert {:error, {:insecure_or_invalid_url, _}} =
             OAuth.begin("http://evil.example/mcp",
               redirect_uri: "http://localhost:1234/cb",
               request: fn _, _, _, _, _ -> :error end
             )

    assert {:error, :invalid_loopback_redirect} =
             OAuth.begin("https://mcp.example/mcp",
               redirect_uri: "http://evil.example/cb",
               request: fn _, _, _, _, _ -> :error end
             )
  end
end
