defmodule Tackle.Web.CodexDeviceTest do
  use Tackle.Web.DataCase, async: true

  alias Tackle.Lib.CredentialStore, as: Store
  alias Tackle.Web.{CodexLoginLive, CredentialStore}
  alias Tackle.Web.Models.{CodexDevice, Provider}

  defmodule OAuth do
    @moduledoc false
    def request_device_code(opts) do
      send(Keyword.fetch!(opts, :test_pid), :requested)
      Keyword.fetch!(opts, :request_result)
    end

    def complete_device_code(device, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:completed, device})
      Keyword.fetch!(opts, :complete_result)
    end
  end

  test "device login saves returned credentials in the correct namespace, not in its result" do
    Provider.register!("work", :codex)
    Provider.register!("home", :codex)
    device = %{user_code: "ABCD", verification_uri: "https://example.test/device"}
    credentials = %{"access_token" => "secret", "refresh_token" => "refresh"}

    opts = [
      oauth_module: OAuth,
      test_pid: self(),
      request_result: {:ok, device},
      complete_result: {:ok, credentials}
    ]

    assert {:ok, flow} = CodexDevice.request("work", opts)
    assert flow == %{provider_id: "work", device: device}
    assert_received :requested
    assert CodexDevice.complete(flow, opts) == :ok
    assert_received {:completed, ^device}
    assert Store.fetch(CredentialStore.handle(), "work") == {:ok, credentials}
    assert Store.fetch(CredentialStore.handle(), "home") == :error
  end

  test "request failures, timeout/denial and invalid providers do not overwrite credentials" do
    Provider.register!("work", :codex)
    Provider.register!("router", :openrouter)
    handle = CredentialStore.handle()
    :ok = Store.put(handle, "work", %{"refresh_token" => "existing"})
    opts = [oauth_module: OAuth, test_pid: self(), request_result: {:error, :unavailable}]
    assert {:error, :unavailable} = CodexDevice.request("work", opts)
    assert {:error, :not_a_codex_provider} = CodexDevice.request("router", opts)
    assert {:error, {:unknown_provider, "missing"}} = CodexDevice.request("missing", opts)

    for reason <- [:device_code_expired, :access_denied, :cancelled] do
      assert {:error, ^reason} =
               CodexDevice.complete(
                 %{provider_id: "work", device: %{}},
                 Keyword.put(opts, :complete_result, {:error, reason})
               )

      assert Store.fetch(handle, "work") == {:ok, %{"refresh_token" => "existing"}}
    end
  end

  test "real OAuth helper exchanges a fake device code and persists tokens, propagating expiry" do
    Provider.register!("work", :codex)

    claims =
      JSON.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account"}})

    access_token = "header.#{Base.url_encode64(claims, padding: false)}.signature"

    request = fn options ->
      case URI.parse(options[:url]).path do
        "/api/accounts/deviceauth/usercode" ->
          {:ok,
           %{
             status: 200,
             body: %{"device_auth_id" => "device", "user_code" => "CODE", "interval" => "1"}
           }}

        "/api/accounts/deviceauth/token" ->
          assert JSON.decode!(options[:body])["device_auth_id"] == "device"

          {:ok,
           %{
             status: 200,
             body: %{"authorization_code" => "authorized", "code_verifier" => "verifier"}
           }}

        "/oauth/token" ->
          assert options[:form][:redirect_uri] == "https://auth.openai.com/deviceauth/callback"

          {:ok,
           %{
             status: 200,
             body: %{
               "access_token" => access_token,
               "refresh_token" => "rotating",
               "expires_in" => 3600
             }
           }}
      end
    end

    opts = [request: request, now: 1000, device_timeout_ms: 60_000]
    assert {:ok, flow} = CodexDevice.request("work", opts)
    assert flow.device.verification_uri == "https://auth.openai.com/codex/device"
    assert flow.device.user_code == "CODE"
    assert CodexDevice.complete(flow, opts) == :ok
    assert {:ok, credentials} = Store.fetch(CredentialStore.handle(), "work")
    assert credentials["access_token"] == access_token
    assert credentials["refresh_token"] == "rotating"
    assert credentials["account_id"] == "account"

    assert {:error, :device_code_expired} =
             CodexDevice.complete(flow, Keyword.put(opts, :now, 61_000))

    assert Store.fetch(CredentialStore.handle(), "work") == {:ok, credentials}
  end

  test "page is unmounted and fails closed until admin authentication exists" do
    refute Enum.any?(Phoenix.Router.routes(Tackle.Web.Router), &(&1.plug == CodexLoginLive))

    assert {:error, :admin_authentication_not_implemented} =
             CodexLoginLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
  end

  test "page does not display upstream error details or completed device codes" do
    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, %{
        device: %{user_code: "code"},
        status: :waiting
      })

    assert {:noreply, failed} =
             CodexLoginLive.handle_async(
               :complete_login,
               {:ok, {:error, %{"secret" => "do-not-render"}}},
               socket
             )

    assert failed.assigns.status == :failed
    assert failed.assigns.device == nil
    assert {:noreply, complete} = CodexLoginLive.handle_async(:complete_login, {:ok, :ok}, socket)
    assert complete.assigns.status == :complete
    assert complete.assigns.device == nil
  end
end
