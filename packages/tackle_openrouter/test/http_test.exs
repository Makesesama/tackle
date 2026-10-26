defmodule Tackle.Plugins.OpenRouter.HTTPTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM.Error
  alias Tackle.Plugins.OpenRouter.HTTP

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

    assert {:error, %Error{kind: :timeout, details: :timeout}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> {:error, :timeout} end
             )

    assert {:error, %Error{kind: :unknown, message: "The provider request failed: boom"}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> raise "boom" end
             )

    assert {:error, %Error{kind: :invalid_response, details: :unexpected}} =
             HTTP.stream([], nil, callback,
               stream: fn _options, _initial, _callback -> :unexpected end
             )
  end

  test "reports Req transport failures as retryable errors" do
    callback = fn _chunk, _response, acc -> {:cont, acc} end

    for reason <- [:closed, :econnrefused, :econnreset, :nxdomain] do
      stream = fn _options, _initial, _callback ->
        {:error, %Req.TransportError{reason: reason}}
      end

      assert {:error, %Error{kind: :transport} = error} =
               HTTP.stream([], nil, callback, stream: stream)

      assert Tackle.Lib.Retry.retryable?(error)
    end
  end
end
