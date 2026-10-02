defmodule Tackle.Plugins.Anthropic.OAuthTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.JSON
  alias Tackle.Plugins.Anthropic.OAuth

  @token_url "https://token.test/v1/oauth/token"

  test "starts a PKCE authorization flow with the expected parameters" do
    assert {:ok, flow} = OAuth.begin_authorization(token_url: @token_url)

    uri = URI.parse(flow.url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "claude.ai"
    assert uri.path == "/oauth/authorize"
    assert params["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    assert params["response_type"] == "code"
    assert params["redirect_uri"] == "https://platform.claude.com/oauth/code/callback"
    assert params["code_challenge_method"] == "S256"
    assert params["code"] == "true"
    assert params["state"] == flow.state
    assert params["scope"] =~ "user:sessions:claude_code"
    assert is_binary(flow.verifier)
  end

  test "exchanges a code#state callback for credentials" do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})
      token_response()
    end

    assert {:ok, flow} = OAuth.begin_authorization()
    input = "auth-code##{flow.state}"

    assert {:ok, credentials} =
             OAuth.exchange_callback(flow, input, token_url: @token_url, request: request, now: 0)

    assert credentials["type"] == "oauth"
    assert credentials["access_token"] == "sk-ant-oat-1"
    assert credentials["refresh_token"] == "refresh-1"
    assert credentials["expires_at"] == 3_600_000 - 300_000

    assert_receive {:request, options}
    assert options[:url] == @token_url
    assert options[:method] == :post

    assert {:ok, body} = JSON.decode(options[:body])
    assert body["grant_type"] == "authorization_code"
    assert body["code"] == "auth-code"
    assert body["state"] == flow.state
    assert body["redirect_uri"] == flow.redirect_uri
    assert body["code_verifier"] == flow.verifier
  end

  test "accepts a full redirect URL and a raw query string" do
    assert {:ok, flow} = OAuth.begin_authorization()
    request = fn _options -> token_response() end

    url = "https://platform.claude.com/oauth/code/callback?code=abc&state=#{flow.state}"

    assert {:ok, _credentials} =
             OAuth.exchange_callback(flow, url, token_url: @token_url, request: request)

    assert {:ok, _credentials} =
             OAuth.exchange_callback(flow, "code=abc&state=#{flow.state}",
               token_url: @token_url,
               request: request
             )
  end

  test "rejects a mismatched state and unparseable input" do
    assert {:ok, flow} = OAuth.begin_authorization()

    assert {:error, :oauth_state_mismatch} =
             OAuth.exchange_callback(flow, "abc#wrong", token_url: @token_url)

    assert {:error, :invalid_oauth_callback} =
             OAuth.exchange_callback(flow, "not-a-callback", token_url: @token_url)
  end

  test "refreshes a credential, preserving a rotated or fallback refresh token" do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})

      {:ok,
       %Req.Response{
         status: 200,
         body:
           JSON.encode!(%{
             "access_token" => "sk-ant-oat-2",
             "expires_in" => 1_000
           })
       }}
    end

    credentials = %{
      "access_token" => "sk-ant-oat-1",
      "refresh_token" => "refresh-1",
      "expires_at" => 0
    }

    assert {:ok, refreshed} =
             OAuth.refresh(credentials, token_url: @token_url, request: request, now: 500)

    assert refreshed["access_token"] == "sk-ant-oat-2"
    assert refreshed["refresh_token"] == "refresh-1"
    assert refreshed["expires_at"] == 500 + 1_000 * 1_000 - 300_000

    assert_receive {:request, options}
    assert {:ok, body} = JSON.decode(options[:body])
    assert body["grant_type"] == "refresh_token"
    assert body["refresh_token"] == "refresh-1"
    assert body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  end

  test "retries retryable token failures and honors x-should-retry false" do
    test_pid = self()

    request = fn _options ->
      send(test_pid, :attempt)

      case Process.get(:attempts, 0) do
        0 ->
          Process.put(:attempts, 1)
          {:ok, %Req.Response{status: 500, headers: %{}, body: "boom"}}

        _other ->
          token_response()
      end
    end

    sleeps = fn ms -> send(test_pid, {:sleep, ms}) end

    assert {:ok, credentials} =
             OAuth.exchange_code(
               "code",
               "state",
               "verifier",
               "https://redirect.test",
               token_url: @token_url,
               request: request,
               sleep: sleeps
             )

    assert credentials["access_token"] == "sk-ant-oat-1"
    assert_receive :attempt
    assert_receive :attempt
    assert_receive {:sleep, 5_000}

    Process.delete(:attempts)

    no_retry = fn _options ->
      {:ok, %Req.Response{status: 500, headers: %{"x-should-retry" => "false"}, body: "nope"}}
    end

    assert {:error, {:token_request_failed, :exchange, 500, "nope"}} =
             OAuth.exchange_code(
               "code",
               "state",
               "verifier",
               "https://redirect.test",
               token_url: @token_url,
               request: no_retry
             )
  end

  test "detects expiry and classifies oauth tokens" do
    assert OAuth.expired?(%{"expires_at" => 1_000}, now: 2_000)
    refute OAuth.expired?(%{"expires_at" => 5_000}, now: 1_000)
    assert OAuth.expired?(%{"access_token" => "x"})

    assert OAuth.is_oauth_token("sk-ant-oat-xyz")
    refute OAuth.is_oauth_token("sk-ant-api03-xyz")
    refute OAuth.is_oauth_token(nil)

    assert {:ok, %{access_token: "sk-ant-oat-1"}} =
             OAuth.access(%{"access_token" => "sk-ant-oat-1"})
  end

  defp token_response do
    {:ok,
     %Req.Response{
       status: 200,
       headers: %{},
       body:
         JSON.encode!(%{
           "access_token" => "sk-ant-oat-1",
           "refresh_token" => "refresh-1",
           "expires_in" => 3_600
         })
     }}
  end
end
