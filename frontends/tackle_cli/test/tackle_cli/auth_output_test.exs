defmodule Tackle.CLI.Output.AuthTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Auth

  @provider %{
    id: "example",
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
    assert rendered =~ "yes"
    refute rendered =~ "╭"
    refute rendered =~ "\e["
  end

  test "narrow status output switches to stacked providers" do
    output = Output.new(format: :human, color: :never, width: 40)

    rendered =
      plain(Auth.render_status([%{provider: @provider, result: {:ok, :missing}}], output))

    assert rendered == "example\n  missing · login yes · usage yes"
  end

  test "plain and JSON status outputs are stable and structured" do
    entries = [%{provider: @provider, result: {:ok, :stored}}]

    assert plain(Auth.render_status(entries, Output.new(format: :plain))) ==
             "provider\tstatus\tlogin\tusage\nexample\tstored\tyes\tyes"

    decoded =
      entries |> Auth.render_status(Output.new(format: :json)) |> plain() |> JSON.decode!()

    assert [provider] = decoded["providers"]
    assert provider["provider"] == "example"
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

  test "empty auth collections retain useful output shapes" do
    assert plain(Auth.render_status([], Output.new(color: :never))) ==
             "No authentication providers are configured."

    assert plain(Auth.render_usage([], Output.new(color: :never))) ==
             "No configured providers report account usage."

    assert plain(Auth.render_status([], Output.new(format: :plain))) ==
             "provider\tstatus\tlogin\tusage"

    assert [] ==
             []
             |> Auth.render_usage(Output.new(format: :json))
             |> plain()
             |> JSON.decode!()
             |> Map.fetch!("providers")
  end

  defp plain(data), do: data |> Owl.Data.untag() |> IO.iodata_to_binary()
end
