defmodule Tackle.Lib.LLM.ResponseTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage

  doctest Response

  describe "from_result/1" do
    test "normalizes content, thinking, tool calls, and metadata" do
      usage = %Usage{input_tokens: 10, output_tokens: 2, total_tokens: 12}

      assert {:ok,
              %Response{
                content: "Let me look.",
                thinking: "need a tool",
                tool_calls: [
                  %Call{id: "c1", name: "read", arguments: %{"path" => "a.ex"}},
                  %Call{id: nil, name: "bash", arguments: %{}}
                ],
                usage: ^usage,
                model: "test/model",
                provider: "test",
                provider_state: %{"opaque" => "state"}
              }} =
               Response.from_result(%{
                 data: %{
                   "content" => "Let me look.",
                   "thinking" => "need a tool",
                   "tool_calls" => [
                     %{"id" => "c1", "name" => "read", "arguments" => ~s({"path":"a.ex"})},
                     %{function: %{name: "bash"}}
                   ]
                 },
                 usage: usage,
                 model: "test/model",
                 provider: "test",
                 provider_state: %{"opaque" => "state"}
               })
    end

    test "keeps the data map" do
      data = %{"content" => "hi", "scores" => [%{"id" => "C1"}]}
      assert {:ok, %Response{data: ^data, content: "hi"}} = Response.from_result(%{data: data})
    end

    test "missing fields default to nil and no tool calls" do
      assert {:ok,
              %Response{
                data: %{},
                content: nil,
                thinking: nil,
                tool_calls: [],
                usage: nil,
                model: nil,
                provider: nil,
                provider_state: nil
              }} = Response.from_result(%{data: %{}})

      assert {:ok, %Response{tool_calls: []}} =
               Response.from_result(%{data: %{"content" => "hi", "tool_calls" => nil}})
    end

    test "accepts atom keys, preferring string keys" do
      assert {:ok,
              %Response{
                content: "atom",
                thinking: "string",
                tool_calls: [%Call{name: "read"}]
              }} =
               Response.from_result(%{
                 data: %{
                   :content => "atom",
                   "thinking" => "string",
                   :thinking => "ignored",
                   :tool_calls => [%{name: "read"}]
                 }
               })
    end

    test "keeps tool calls whose arguments are unusable, marked with the argument error" do
      # Codex builds calls with "arguments" => "" for tools without parameters.
      assert {:ok,
              %Response{
                tool_calls: [
                  %Call{id: "c1", name: "read", arguments: %{}, argument_error: :invalid_json},
                  %Call{id: "c2", name: "read", arguments: %{}, argument_error: :not_an_object},
                  %Call{id: "c3", name: "status", arguments: %{}, argument_error: nil}
                ]
              }} =
               Response.from_result(%{
                 data: %{
                   "tool_calls" => [
                     %{"id" => "c1", "name" => "read", "arguments" => ~s({"path": )},
                     %{"id" => "c2", "name" => "read", "arguments" => "[]"},
                     %{"id" => "c3", "name" => "status", "arguments" => ""}
                   ]
                 }
               })
    end

    test "normalizes a provider usage map" do
      assert {:ok, %Response{usage: %Usage{input_tokens: 5, output_tokens: 4}}} =
               Response.from_result(%{
                 data: %{"content" => "hi"},
                 usage: %{input_tokens: 5, output_tokens: 4}
               })
    end

    test "rejects malformed results" do
      for {result, detail} <- [
            {%{}, {:data, nil}},
            {%{data: nil}, {:data, nil}},
            {%{data: "text"}, {:data, "text"}},
            {"text", {:result, "text"}},
            {%{data: %{"content" => 42}}, {:content, 42}},
            {%{data: %{content: :hello}}, {:content, :hello}},
            {%{data: %{"thinking" => ["a"]}}, {:thinking, ["a"]}},
            {%{data: %{"tool_calls" => "read"}}, {:tool_calls, :not_a_list}},
            {%{data: %{"tool_calls" => [nil]}}, {:tool_calls, :malformed_tool_call}},
            {%{data: %{}, usage: 12}, {:usage, 12}},
            {%{data: %{}, provider_state: "opaque"}, {:provider_state, "opaque"}}
          ] do
        assert Response.from_result(result) == {:error, {:invalid_response, detail}},
               inspect(result)
      end
    end
  end

  describe "empty?/1" do
    test "is true without content and tool calls" do
      assert Response.empty?(%Response{})
      assert Response.empty?(%Response{content: "", thinking: "only reasoning"})
    end

    test "is false with content or tool calls" do
      refute Response.empty?(%Response{content: "answer"})
      refute Response.empty?(%Response{tool_calls: [%Call{name: "read"}]})
      refute Response.empty?(%Response{content: "", tool_calls: [%Call{name: "read"}]})
    end
  end
end
