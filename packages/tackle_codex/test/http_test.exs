defmodule Tackle.Plugins.Codex.HTTPTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Codex.HTTP

  test "streams with an explicit accumulator and no into request option" do
    test_pid = self()

    stream = fn options, initial_acc, callback ->
      send(test_pid, {:stream_options, options})
      response = %Req.Response{status: 200, body: nil}

      {:cont, acc} = callback.("hel", response, initial_acc)
      {:cont, acc} = callback.("lo", response, acc)
      {:ok, response, acc}
    end

    callback = fn chunk, _response, acc -> {:cont, acc <> chunk} end

    assert {:ok, %Req.Response{status: 200, body: "hello"}} =
             HTTP.stream([url: "https://example.test"], "", callback, stream: stream)

    assert_receive {:stream_options, options}
    refute Keyword.has_key?(options, :into)
  end
end
