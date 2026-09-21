defmodule Tackle.Plugins.DeepSeek.HTTPTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.DeepSeek.HTTP

  test "normalizes an injected three-tuple stream result" do
    stream = fn options, initial, callback ->
      response = %Req.Response{status: 200, body: nil}
      assert {:cont, updated} = callback.("chunk", response, initial)
      send(self(), {:options, options})
      {:ok, response, updated}
    end

    callback = fn chunk, _response, acc -> {:cont, acc <> chunk} end

    assert {:ok, %Req.Response{status: 200, body: "chunk"}} =
             HTTP.stream([url: "https://example.test"], "", callback, stream: stream)

    assert_receive {:options, [url: "https://example.test"]}
  end

  test "wraps request failures, exceptions, and invalid responses" do
    callback = fn _chunk, _response, acc -> {:cont, acc} end

    assert {:error, {:request_failed, :timeout}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> {:error, :timeout} end
             )

    assert {:error, {:request_failed, "boom"}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> raise "boom" end
             )

    assert {:error, {:invalid_http_response, :unexpected}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> :unexpected end
             )
  end

  test "bounds provider error bodies" do
    assert HTTP.error_body(%{"error" => "bad"}) == %{"error" => "bad"}
    assert HTTP.error_body(String.duplicate("x", 5_000)) == String.duplicate("x", 4_096)
    assert HTTP.error_body({:unexpected, :body}) == "{:unexpected, :body}"
  end
end
