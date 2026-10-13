defmodule Tackle.Web.ProvidersTest do
  # The adapter list and the default model are global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Web.ChatFixture
  alias Tackle.Web.FakeAdapter
  alias Tackle.Web.Providers

  setup do
    ChatFixture.setup()
  end

  test "the chat host validates its selected catalog" do
    assert {:ok, catalog} = Providers.catalog()
    assert Tackle.Plugins.Catalog.adapter_modules(catalog) == [FakeAdapter]

    assert {:ok, [%{module: Tackle.Tools.Read, source: :tackle}]} =
             Tackle.Plugins.Catalog.resolve_tools(catalog, ["read"])
  end

  test "the adapters are the configured plugins" do
    assert Providers.adapters() == [FakeAdapter]
  end

  test "the models are the references those adapters expose" do
    assert Providers.models() == ["fake/echo", "fake/echo-2"]
  end

  test "the default model is the configured one" do
    assert Providers.default_model() == "fake/echo"
  end

  test "a model reference resolves to the adapter that offers it" do
    assert {:ok, selection} = Providers.select("fake/echo-2")

    assert selection.adapter == FakeAdapter
    assert selection.model == "echo-2"
  end

  test "nil resolves to the default model" do
    assert {:ok, selection} = Providers.select(nil)

    assert selection.model == "echo"
  end

  test "a model no adapter offers is reported" do
    assert {:error, {:unknown_model, "fake/nope"}} = Providers.select("fake/nope")
  end

  test "a reference names a provider, not an adapter module" do
    assert [%Tackle.Lib.LLM.Provider{id: "fake", adapter: FakeAdapter}] = Providers.providers()

    assert {:ok, selection} = Providers.select("fake/echo")
    assert selection.provider_id == "fake"

    assert {:error, {:unknown_provider, "fake-work"}} = Providers.select("fake-work/echo")

    assert Tackle.Web.ChatError.message({:unknown_provider, "fake-work"}) =~
             "The provider fake-work is not configured."
  end

  test "config.json providers are offered and selectable", %{root: root} do
    home = Path.join(root, "home")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"fake-work" => %{"adapter" => "fake"}}})
    )

    assert Enum.map(Providers.providers(), & &1.id) == ["fake", "fake-work"]
    assert "fake-work/echo-2" in Providers.models()

    assert {:ok, selection} = Providers.select("fake-work/echo-2")
    assert selection.adapter == FakeAdapter
    assert selection.provider_id == "fake-work"
    assert selection.ref == "fake-work/echo-2"
  end

  test "an invalid provider configuration is reported by select", %{root: root} do
    home = Path.join(root, "home")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"other" => %{"adapter" => "missing"}}})
    )

    assert Providers.providers() == []

    assert {:error, {:unknown_provider_adapter, "other", "missing"} = reason} =
             Providers.select("fake/echo")

    assert Tackle.Web.ChatError.message(reason) =~ "names the adapter missing"
  end

  describe "with nothing configured" do
    setup do
      previous = Application.get_env(:tackle, :adapters)

      Application.delete_env(:tackle_web, :agent_adapters)
      Application.delete_env(:tackle_web, :agent_model)
      Application.delete_env(:tackle, :adapters)

      on_exit(fn ->
        if previous, do: Application.put_env(:tackle, :adapters, previous)
      end)
    end

    test "there are no adapters and no models" do
      assert Providers.adapters() == []
      assert Providers.models() == []
      assert Providers.default_model() == nil
    end

    test "selecting a model says so instead of looping" do
      assert {:error, :no_model_available} = Providers.select(nil)
    end
  end
end
