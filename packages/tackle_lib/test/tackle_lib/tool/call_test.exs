defmodule Tackle.Lib.Tool.CallTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool.Call

  doctest Call

  describe "normalize/1" do
    test "keeps a named call whose arguments are not valid JSON, with its id" do
      for arguments <- ["{", ~s({"path": ), "not json", <<255>>] do
        assert {:ok,
                %Call{
                  id: "c1",
                  name: "read",
                  arguments: %{},
                  argument_error: :invalid_json
                }} = Call.normalize(%{"id" => "c1", "name" => "read", "arguments" => arguments}),
               inspect(arguments)
      end
    end

    test "keeps a named call whose arguments are not an object" do
      for arguments <- ["[]", "42", ~s("text"), "null", [1], 42] do
        assert {:ok, %Call{name: "read", arguments: %{}, argument_error: :not_an_object}} =
                 Call.normalize(%{name: "read", arguments: arguments}),
               inspect(arguments)
      end
    end

    test "treats missing, empty, and blank argument strings as no arguments" do
      for call <- [
            %{"name" => "status"},
            %{"name" => "status", "arguments" => nil},
            %{"name" => "status", "arguments" => ""},
            %{"function" => %{"name" => "status", "arguments" => " \n"}}
          ] do
        assert {:ok, %Call{name: "status", arguments: %{}, argument_error: nil}} =
                 Call.normalize(call),
               inspect(call)
      end
    end

    test "normalizes the arguments of a Call struct" do
      call = %Call{id: "c1", name: "read", arguments: %{"path" => "a"}}
      assert Call.normalize(call) == {:ok, call}

      assert {:ok, %Call{arguments: %{"path" => "a"}, argument_error: nil}} =
               Call.normalize(%Call{name: "read", arguments: ~s({"path":"a"})})

      assert {:ok, %Call{arguments: %{}, argument_error: :invalid_json}} =
               Call.normalize(%Call{name: "read", arguments: "{"})
    end

    test "rejects calls without a name" do
      for call <- [nil, "read", %{"arguments" => %{}}, %{"name" => ""}, %Call{name: nil}] do
        assert Call.normalize(call) == {:error, :malformed_tool_call}, inspect(call)
      end
    end
  end
end
