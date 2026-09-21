defmodule Tackle.Plugins.Codex.OAuthTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Codex.OAuth
  alias Tackle.Plugins.Codex.PKCE

  test "builds an authorization URL with state and an S256 PKCE challenge" do
    assert %{verifier: verifier, challenge: challenge} = PKCE.generate()

    assert challenge ==
             :sha256
             |> :crypto.hash(verifier)
             |> Base.url_encode64(padding: false)

    assert byte_size(verifier) in 43..128

    assert {:ok, flow} = OAuth.begin_authorization(originator: "test")
    query = flow.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
    assert query["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert query["code_challenge_method"] == "S256"
    assert query["state"] == flow.state
    assert query["originator"] == "test"
  end

  test "validates callback state and exchanges the authorization code" do
    access_token = jwt("account-from-token")
    test_pid = self()

    request = fn options ->
      send(test_pid, {:token_request, options})

      {:ok,
       %Req.Response{
         status: 200,
         body:
           JSON.encode!(%{
             "access_token" => access_token,
             "refresh_token" => "refresh-token",
             "expires_in" => 3_600
           })
       }}
    end

    flow = %{
      state: "expected-state",
      verifier: "verifier",
      redirect_uri: "http://localhost:1455/auth/callback"
    }

    assert {:error, :oauth_state_mismatch} =
             OAuth.exchange_callback(flow, %{code: "code", state: "wrong"}, request: request)

    assert {:ok, credentials} =
             OAuth.exchange_callback(
               flow,
               "http://localhost:1455/auth/callback?code=auth-code&state=expected-state",
               request: request,
               now: 1_000
             )

    assert credentials == %{
             "type" => "oauth",
             "access_token" => access_token,
             "refresh_token" => "refresh-token",
             "expires_at" => 3_601_000,
             "account_id" => "account-from-token"
           }

    assert_receive {:token_request, options}
    assert options[:url] == "https://auth.openai.com/oauth/token"
    assert options[:form][:grant_type] == "authorization_code"
    assert options[:form][:code] == "auth-code"
    assert options[:form][:code_verifier] == "verifier"
  end

  test "completes the provider-specific device-code flow" do
    access_token = jwt("device-account")
    counter = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    request = fn options ->
      cond do
        String.ends_with?(options[:url], "/deviceauth/usercode") ->
          {:ok,
           %Req.Response{
             status: 200,
             body:
               JSON.encode!(%{
                 "device_auth_id" => "device-id",
                 "user_code" => "ABCD-EFGH",
                 "interval" => "0"
               })
           }}

        String.ends_with?(options[:url], "/deviceauth/token") ->
          poll = Agent.get_and_update(counter, &{&1, &1 + 1})

          if poll == 0 do
            {:ok, %Req.Response{status: 403, body: ""}}
          else
            {:ok,
             %Req.Response{
               status: 200,
               body:
                 JSON.encode!(%{
                   "authorization_code" => "device-code",
                   "code_verifier" => "device-verifier"
                 })
             }}
          end

        String.ends_with?(options[:url], "/oauth/token") ->
          assert options[:form][:redirect_uri] == "https://auth.openai.com/deviceauth/callback"

          {:ok,
           %Req.Response{
             status: 200,
             body:
               JSON.encode!(%{
                 "access_token" => access_token,
                 "refresh_token" => "device-refresh",
                 "expires_in" => 3_600
               })
           }}
      end
    end

    assert {:ok, device} =
             OAuth.request_device_code(request: request, now: 1_000, device_timeout_ms: 60_000)

    assert device.user_code == "ABCD-EFGH"
    assert device.verification_uri == "https://auth.openai.com/codex/device"
    assert device.interval_ms == 1_000

    assert {:ok, credentials} =
             OAuth.complete_device_code(device,
               request: request,
               now: 1_000,
               sleep: fn _milliseconds -> :ok end
             )

    assert credentials["access_token"] == access_token
    assert credentials["refresh_token"] == "device-refresh"
    assert credentials["account_id"] == "device-account"
  end

  test "refresh retains the old refresh token when OpenAI does not rotate it" do
    new_access = jwt("same-account")

    request = fn options ->
      assert options[:form][:grant_type] == "refresh_token"
      assert options[:form][:refresh_token] == "existing-refresh"

      {:ok,
       %Req.Response{
         status: 200,
         body: JSON.encode!(%{"access_token" => new_access, "expires_in" => 60})
       }}
    end

    assert {:ok, refreshed} =
             OAuth.refresh(%{"refresh_token" => "existing-refresh"},
               request: request,
               now: 10_000
             )

    assert refreshed["refresh_token"] == "existing-refresh"
    assert refreshed["expires_at"] == 70_000
  end

  defp jwt(account_id) do
    payload =
      JSON.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header.#{Base.url_encode64(payload, padding: false)}.signature"
  end
end
