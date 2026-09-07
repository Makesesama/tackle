defmodule Tackle.JSONTest do
  use ExUnit.Case, async: false

  defmodule TestJSONAdapter do
    @behaviour Tackle.JSON

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
    previous = Application.get_env(:tackle, :json)

    on_exit(fn ->
      if previous do
        Application.put_env(:tackle, :json, previous)
      else
        Application.delete_env(:tackle, :json)
      end
    end)
  end

  test "uses built-in JSON adapter by default" do
    Application.delete_env(:tackle, :json)

    assert Tackle.JSON.adapter() == Tackle.JSON.Default
    assert {:ok, encoded} = Tackle.JSON.encode(%{hello: "world"})
    assert {:ok, %{"hello" => "world"}} = Tackle.JSON.decode(encoded)
  end

  test "uses configured JSON adapter" do
    Application.put_env(:tackle, :json, TestJSONAdapter)

    assert Tackle.JSON.adapter() == TestJSONAdapter
    assert {:ok, "custom:%{hello: \"world\"}"} = Tackle.JSON.encode(%{hello: "world"})
    assert "custom!:%{hello: \"world\"}" = Tackle.JSON.encode!(%{hello: "world"})
    assert {:ok, %{"decoded" => true}} = Tackle.JSON.decode("custom")
    assert %{"decoded!" => true} = Tackle.JSON.decode!("custom!")
  end
end
