defmodule Tackle.CLI.Output.AuthTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Auth

  @provider %{
    id: "example",
    adapter: "example",
    source: :default,
    module: Example,
    models: ["one", "two"],
    capabilities: %{login: true, logout: false, status: false, usage: true}
  }

  test "human status output is borderless and reports supported flows" do
    output = Output.new(format: :human, color: :never, width: 80)
    rendered = plain(Auth.render_status([%{provider: @provider, result: {:ok, :stored}}], output))

    assert rendered =~ "PROVIDER"
    assert rendered =~ "example"
    assert rendered =~ "stored"
    assert rendered =~ "LOGIN"
    assert rendered =~ "USAGE"
    assert rendered =~ "SOURCE"
    assert rendered =~ "built-in"
    assert rendered =~ "yes"
    # Every provider is named after its adapter type, so no adapter column.
    refute rendered =~ "ADAPTER"
    refute rendered =~ "╭"
    refute rendered =~ "\e["
  end

  test "human status output names the adapter of providers whose id differs from it" do
    output = Output.new(format: :human, color: :never, width: 100)

    entries = [
      %{provider: @provider, result: {:ok, :stored}},
      %{provider: %{@provider | id: "example-work", source: :account}, result: {:ok, :missing}},
      %{
        provider: %{@provider | id: "local", adapter: "ollama", source: :config},
        result: {:ok, :not_required}
      }
    ]

    lines = entries |> Auth.render_status(output) |> plain() |> String.split("\n")

    assert [header, _divider, default, account, local] = lines
    assert header =~ ~r/PROVIDER\s+ADAPTER\s+SOURCE\s+STATUS\s+LOGIN\s+USAGE/
    assert default =~ ~r/^example\s+built-in\s+stored/
    assert account =~ ~r/^example-work\s+example\s+account\s+missing/
    # A keyless provider has nothing to log in to.
    assert local =~ ~r/^local\s+ollama\s+config\s+not required\s+no\s+yes/
  end

  test "narrow status output switches to stacked providers" do
    output = Output.new(format: :human, color: :never, width: 40)

    rendered =
      plain(Auth.render_status([%{provider: @provider, result: {:ok, :missing}}], output))

    assert rendered == "example\n  missing · login yes · usage yes · built-in"

    account = %{@provider | id: "example-work", source: :account}

    rendered =
      plain(Auth.render_status([%{provider: account, result: {:ok, :stored}}], output))

    assert rendered == "example-work · example\n  stored · login yes · usage yes · account"
  end

  test "plain and JSON status outputs are stable and structured" do
    entries = [%{provider: @provider, result: {:ok, :stored}}]

    assert plain(Auth.render_status(entries, Output.new(format: :plain))) ==
             "provider\tadapter\tsource\tstatus\tlogin\tusage\n" <>
               "example\texample\tdefault\tstored\tyes\tyes"

    decoded =
      entries |> Auth.render_status(Output.new(format: :json)) |> plain() |> JSON.decode!()

    assert [provider] = decoded["providers"]
    assert provider["provider"] == "example"
    assert provider["adapter"] == "example"
    assert provider["source"] == "default"
    assert provider["status"] == "stored"
    assert provider["models"] == ["one", "two"]
    assert provider["capabilities"]["usage"] == true
    assert provider["capabilities"]["logout"] == false
  end

  test "usage renders nested provider maps without Elixir inspect syntax" do
    entries = [
      %{
        provider: "example",
        result:
          {:ok, %{"plan_type" => "pro", "balance" => [%{"currency" => "USD", "total" => "4.20"}]}}
      }
    ]

    rendered = plain(Auth.render_usage(entries, Output.new(format: :human, color: :never)))

    assert rendered =~ "example"
    assert rendered =~ "plan type: pro"
    assert rendered =~ "currency: USD"
    assert rendered =~ "total: 4.20"
    refute rendered =~ "%{"

    plain_output = plain(Auth.render_usage(entries, Output.new(format: :plain)))
    assert plain_output =~ "provider\tstatus\tusage"
    assert plain_output =~ ~s(example\tok\t{"balance")

    decoded = entries |> Auth.render_usage(Output.new(format: :json)) |> plain() |> JSON.decode!()
    assert get_in(decoded, ["providers", Access.at(0), "usage", "plan_type"]) == "pro"
  end

  test "actions use semantic human messages and machine-readable shapes" do
    human = plain(Auth.render_action(:login, "example", :ok, Output.new(color: :never)))
    assert human == "✓ Authenticated with example."

    plain_output =
      plain(Auth.render_action(:logout, "example", :aborted, Output.new(format: :plain)))

    assert plain_output == "action\tprovider\tstatus\nlogout\texample\taborted"

    decoded =
      :logout
      |> Auth.render_action("example", :ok, Output.new(format: :json))
      |> plain()
      |> JSON.decode!()

    assert decoded == %{"action" => "logout", "provider" => "example", "status" => "ok"}
  end

  test "auth errors explain unsupported providers and flows" do
    provider_error = {:unsupported_auth_provider, "missing", {:supported, ["example"]}}
    flow_error = {:unsupported_provider_flow, "example", :usage}

    rendered = plain(Auth.render_error(provider_error, Output.new(color: :never)))
    assert rendered =~ ~s(Provider "missing" is not configured.)
    assert rendered =~ "Available providers: example."
    refute rendered =~ "unsupported_auth_provider"

    rendered = plain(Auth.render_error(flow_error, Output.new(color: :never)))
    assert rendered =~ ~s(Provider "example" does not support auth usage.)
    assert rendered =~ "tackle auth status"

    decoded =
      provider_error
      |> Auth.render_error(Output.new(format: :json))
      |> plain()
      |> JSON.decode!()

    assert decoded["error"]["code"] == "unsupported_auth_provider"
    assert decoded["error"]["message"] =~ "not configured"
  end

  test "provider errors show their message and kind" do
    error = Tackle.Lib.LLM.Error.from_response(401, ~s({"error":{"message":"bad key"}}), [])

    rendered = plain(Auth.render_error(error, Output.new(color: :never)))
    assert rendered =~ "The provider rejected the credentials (HTTP 401): bad key."
    refute rendered =~ "%Tackle.Lib.LLM.Error"

    decoded = error |> Auth.render_error(Output.new(format: :json)) |> plain() |> JSON.decode!()
    assert decoded["error"]["code"] == "auth"

    assert decoded["error"]["message"] ==
             "The provider rejected the credentials (HTTP 401): bad key."
  end

  test "provider instance errors are explained without internal tuples" do
    cases = [
      {{:unknown_provider, "codex-work"}, ~s(Provider "codex-work" is not configured.)},
      {{:login_not_required, "ollama"}, ~s(Provider "ollama" needs no login)},
      {{:invalid_provider_id, "Work"}, ~s("Work" is not a valid provider name.)},
      {{:duplicate_provider_id, "ollama"}, ~s(Provider "ollama" is declared more than once.)},
      {{:provider_adapter_conflict, "work"},
       ~s(The name "work" already belongs to a provider or account of another adapter.)},
      {{:default_provider_name, "ollama"},
       ~s("ollama" is a built-in provider, so an account of that name would never be used.)},
      {{:invalid_account, "work"}, ~s(The recorded account "work" in auth.json is invalid.)},
      {{:duplicate_adapter_type, "ollama"}, ~s(share the adapter type "ollama")},
      {{:invalid_config_provider, "/home/config.json", "work"},
       ~s(Provider "work" in /home/config.json is invalid.)},
      {{:invalid_provider_setting, "work", "base_url", 42},
       ~s(Provider "work" has an invalid "base_url" setting.)},
      {{:invalid_provider_settings, "work", {"api_key", "maybe"}},
       ~s(Provider "work" has invalid settings.)},
      {{:accounts_unavailable, :noproc}, "accounts could not be read"},
      {:no_providers_configured, "No providers are configured."}
    ]

    for {reason, message} <- cases do
      assert plain(Auth.render_error(reason, Output.new(color: :never))) =~ message
    end

    decoded =
      {:invalid_provider_setting, "work", "base_url", 42}
      |> Auth.render_error(Output.new(format: :json))
      |> plain()
      |> JSON.decode!()

    assert decoded["error"]["code"] == "invalid_provider_setting"
  end

  test "missing API keys name the provider and only its own environment setup" do
    render = &plain(Auth.render_error(&1, Output.new(color: :never)))

    rendered = render.({:missing_ollama_api_key, "ollama-cloud"})
    assert rendered =~ ~s(provider "ollama-cloud")
    assert rendered =~ "tackle auth login ollama-cloud"
    assert rendered =~ "OLLAMA_API_KEY"
    refute rendered =~ "missing_ollama_api_key"

    # Another provider of the same adapter does not read the default variable.
    rendered = render.({:missing_ollama_api_key, "cloud2"})
    assert rendered =~ "tackle auth login cloud2"
    assert rendered =~ "api_key_env"
    refute rendered =~ "OLLAMA_API_KEY"

    assert render.({:missing_deepseek_api_key, "deepseek"}) =~ "DEEPSEEK_API_KEY"
    assert render.({:missing_openrouter_api_key, "openrouter"}) =~ "OPENROUTER_API_KEY"
    assert render.({:missing_anthropic_credentials, "anthropic"}) =~ "ANTHROPIC_API_KEY"

    rendered = render.({:missing_deepseek_api_key, "deepseek-work"})
    assert rendered =~ "tackle auth login deepseek-work"
    refute rendered =~ "DEEPSEEK_API_KEY"
  end

  test "empty auth collections retain useful output shapes" do
    assert plain(Auth.render_status([], Output.new(color: :never))) ==
             "No authentication providers are configured."

    assert plain(Auth.render_usage([], Output.new(color: :never))) ==
             "No configured providers report account usage."

    assert plain(Auth.render_status([], Output.new(format: :plain))) ==
             "provider\tadapter\tsource\tstatus\tlogin\tusage"

    assert [] ==
             []
             |> Auth.render_usage(Output.new(format: :json))
             |> plain()
             |> JSON.decode!()
             |> Map.fetch!("providers")
  end

  defp plain(data), do: data |> Owl.Data.untag() |> IO.iodata_to_binary()
end
