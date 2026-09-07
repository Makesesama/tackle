defmodule Tackle.Lib.JSONTest do
  use ExUnit.Case, async: false

  defmodule TestJSONAdapter do
    @behaviour Tackle.Lib.JSON

    @impl true
    def encode(term), do: {:ok, "custom:#{inspect(term)}"}

    @impl true
    def encode!(term), do: "custom!:#{inspect(term)}"

    @impl true
    def decode("custom"), do: {:ok, %{"decoded" => true}}

    @impl true
    def decode!("custom!"), do: %{"decoded!" => true}
  end

  setup do
    previous = Application.get_env(:tackle_lib, :json)

    on_exit(fn ->
      if previous do
        Application.put_env(:tackle_lib, :json, previous)
      else
        Application.delete_env(:tackle_lib, :json)
      end
    end)
  end

  test "uses built-in JSON adapter by default" do
    Application.delete_env(:tackle_lib, :json)

    assert Tackle.Lib.JSON.adapter() == Tackle.Lib.JSON.Default
    assert {:ok, encoded} = Tackle.Lib.JSON.encode(%{hello: "world"})
    assert {:ok, %{"hello" => "world"}} = Tackle.Lib.JSON.decode(encoded)
  end

  test "uses configured JSON adapter" do
    Application.put_env(:tackle_lib, :json, TestJSONAdapter)

    assert Tackle.Lib.JSON.adapter() == TestJSONAdapter
    assert {:ok, "custom:%{hello: \"world\"}"} = Tackle.Lib.JSON.encode(%{hello: "world"})
    assert "custom!:%{hello: \"world\"}" = Tackle.Lib.JSON.encode!(%{hello: "world"})
    assert {:ok, %{"decoded" => true}} = Tackle.Lib.JSON.decode("custom")
    assert %{"decoded!" => true} = Tackle.Lib.JSON.decode!("custom!")
  end

  test "does not read the root harness application config" do
    previous_root = Application.get_env(:tackle, :json)

    on_exit(fn ->
      if previous_root do
        Application.put_env(:tackle, :json, previous_root)
      else
        Application.delete_env(:tackle, :json)
      end
    end)

    Application.delete_env(:tackle_lib, :json)
    Application.put_env(:tackle, :json, TestJSONAdapter)

    assert Tackle.Lib.JSON.adapter() == Tackle.Lib.JSON.Default
  end
end
