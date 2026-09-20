defmodule Tackle.Web.ProvidersTest do
  # The adapter list and the default model are global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Web.ChatFixture
  alias Tackle.Web.FakeAdapter
  alias Tackle.Web.Providers

  setup do
    ChatFixture.setup()
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
