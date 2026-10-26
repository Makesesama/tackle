defmodule Tackle.Lib.LLM.ErrorTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Error

  describe "from_response/3" do
    test "classifies statuses" do
      assert %Error{kind: :auth, status: 401} = Error.from_response(401, "nope", [])
      assert %Error{kind: :auth} = Error.from_response(403, "nope", [])
      assert %Error{kind: :quota_exceeded} = Error.from_response(402, "no credits", [])
      assert %Error{kind: :timeout} = Error.from_response(408, "", [])
      assert %Error{kind: :rate_limited, status: 429} = Error.from_response(429, "", [])
      assert %Error{kind: :invalid_request} = Error.from_response(400, "bad request", [])
      assert %Error{kind: :invalid_request} = Error.from_response(404, "no such model", [])
      assert %Error{kind: :server} = Error.from_response(500, "", [])
      assert %Error{kind: :server} = Error.from_response(502, "", [])
      assert %Error{kind: :overloaded} = Error.from_response(503, "", [])
      assert %Error{kind: :timeout} = Error.from_response(504, "", [])
      assert %Error{kind: :invalid_response} = Error.from_response(302, "", [])
    end

    test "treats Anthropic's 529 and overloaded errors as overloaded" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      }

      assert %Error{kind: :overloaded, status: 529, message: message} =
               Error.from_response(529, body, [])

      assert message == "The provider is overloaded (HTTP 529): Overloaded"
      assert %Error{kind: :overloaded} = Error.from_response(500, body, [])
    end

    test "a quota code on a 429 is not a rate limit" do
      body = %{
        "error" => %{"code" => "insufficient_quota", "message" => "You exceeded your quota"}
      }

      assert %Error{kind: :quota_exceeded, status: 429} = Error.from_response(429, body, [])

      codex =
        ~s({"error":{"type":"usage_limit_reached","message":"The usage limit has been reached"}})

      assert %Error{kind: :quota_exceeded} = Error.from_response(429, codex, [])
    end

    test "reads Retry-After seconds and HTTP dates, and retry-after-ms" do
      assert %Error{kind: :rate_limited, retry_after_ms: 7_000} =
               Error.from_response(429, "", %{"retry-after" => ["7"]})

      assert %Error{retry_after_ms: 1_500} =
               Error.from_response(429, "", [{"Retry-After-Ms", "1500"}])

      date =
        DateTime.utc_now()
        |> DateTime.add(30, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      assert %Error{retry_after_ms: ms} = Error.from_response(429, "", [{"retry-after", date}])
      assert ms in 28_000..30_000
    end

    test "detects overflow only in a 400, 413, or 422 error's code and message" do
      openai = %{
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "This model's maximum context length is 128000 tokens."
        }
      }

      assert %Error{kind: :context_window_exceeded, status: 400} =
               Error.from_response(400, openai, [])

      anthropic =
        ~s({"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 208000 tokens > 200000 maximum"}})

      assert %Error{kind: :context_window_exceeded} = Error.from_response(400, anthropic, [])

      assert %Error{kind: :context_window_exceeded} =
               Error.from_response(413, "Input is too long", [])

      relayed = %{
        "error" => %{
          "code" => 400,
          "message" => "Provider returned error",
          "metadata" => %{"raw" => "maximum context length exceeded"}
        }
      }

      assert %Error{kind: :context_window_exceeded} = Error.from_response(400, relayed, [])

      echoed = %{"error" => %{"message" => "invalid tool", "param" => "prompt is too long"}}
      assert %Error{kind: :invalid_request} = Error.from_response(400, echoed, [])
      assert %Error{kind: :server} = Error.from_response(500, openai, [])

      assert %Error{kind: :rate_limited} =
               Error.from_response(429, "too many tokens per minute", [])
    end

    test "keeps the decoded body as details and a bounded single-line message" do
      error = Error.from_response(400, ~s({"error":{"message":"bad\\n  field"}}), [])

      assert error.details == %{"error" => %{"message" => "bad\n  field"}}
      assert error.message == "The provider rejected the request (HTTP 400): bad field"
      assert Exception.message(error) == error.message

      long = Error.from_response(400, String.duplicate("x", 20_000), [])
      assert byte_size(long.details) == 16_384
      assert String.length(long.message) < 600

      html = Error.from_response(502, "<html><body>Bad gateway</body></html>", [])
      assert html.message == "The provider failed (HTTP 502)"
    end
  end

  describe "retry_after_ms/2" do
    test "parses seconds, fractions, dates, and ignores invalid values" do
      now = ~U[2026-01-01 12:00:00Z]

      assert Error.retry_after_ms(%{"retry-after" => ["2"]}, now) == 2_000
      assert Error.retry_after_ms([{"retry-after", "0.5"}], now) == 500

      assert Error.retry_after_ms([{"retry-after", "Thu, 01 Jan 2026 12:00:42 GMT"}], now) ==
               42_000

      assert Error.retry_after_ms([{"retry-after", "Thu, 01 Jan 2026 11:00:00 GMT"}], now) == 0
      assert Error.retry_after_ms([{"retry-after", "soon"}], now) == nil
      assert Error.retry_after_ms([{"retry-after", "-3"}], now) == nil
      assert Error.retry_after_ms([], now) == nil
      assert Error.retry_after_ms([{"retry-after-ms", "250"}, {"retry-after", "9"}], now) == 250
    end
  end

  describe "from_transport/1" do
    test "classifies timeouts apart from other transport failures" do
      assert %Error{kind: :timeout, details: :timeout} = Error.from_transport(:timeout)

      assert %Error{kind: :timeout} =
               Error.from_transport({:exit, {:timeout, {GenServer, :call, []}}})

      assert %Error{kind: :transport, message: message} = Error.from_transport(:econnrefused)
      assert message == "The connection to the provider failed: econnrefused"

      exception = RuntimeError.exception("socket closed")
      assert %Error{kind: :transport, details: ^exception} = Error.from_transport(exception)
    end
  end

  describe "from_caught/2" do
    test "treats exits as transport failures and raises as unknown" do
      assert %Error{kind: :timeout} =
               Error.from_caught(:exit, {:timeout, {NimblePool, :checkout, []}})

      assert %Error{kind: :transport} = Error.from_caught(:exit, :noproc)

      assert %Error{kind: :unknown, message: "The provider request failed: boom"} =
               Error.from_caught(:error, RuntimeError.exception("boom"))

      assert %Error{kind: :unknown, details: %ArgumentError{}} =
               Error.from_caught(:error, :badarg)

      assert %Error{kind: :unknown, details: {:throw, :oops}} = Error.from_caught(:throw, :oops)
    end
  end

  describe "from_stream/1" do
    test "classifies provider error codes and types" do
      assert %Error{kind: :context_window_exceeded} =
               Error.from_stream(%{"code" => "context_length_exceeded", "message" => "too long"})

      assert %Error{kind: :overloaded} =
               Error.from_stream(%{"type" => "overloaded_error", "message" => "Overloaded"})

      assert %Error{kind: :rate_limited} = Error.from_stream(%{"code" => "rate_limit_exceeded"})

      assert %Error{kind: :server, message: message} =
               Error.from_stream(%{"error" => %{"type" => "server_error", "message" => "oops"}})

      assert message == "The provider failed: oops"
      assert %Error{kind: :quota_exceeded} = Error.from_stream(%{"code" => "insufficient_quota"})
      assert %Error{kind: :unknown} = Error.from_stream(%{"code" => "something_new"})
      assert %Error{kind: :unknown} = Error.from_stream("it broke")
      assert %Error{kind: :context_window_exceeded} = Error.from_stream("Prompt is too long")
    end

    test "reads a relayed upstream status and Retry-After beside the error" do
      event = %{
        "type" => "error",
        "status" => 429,
        "error" => %{"type" => "rate_limit_exceeded", "message" => "Slow down"},
        "headers" => %{"retry-after" => "12"}
      }

      assert %Error{kind: :rate_limited, status: 429, retry_after_ms: 12_000} =
               Error.from_stream(event)
    end

    test "uses relayed numeric status codes" do
      assert %Error{kind: :rate_limited, status: 429} =
               Error.from_stream(%{"code" => 429, "message" => "Rate limit exceeded"})

      assert %Error{kind: :server, status: 502} = Error.from_stream(%{"code" => 502})

      assert %Error{kind: :context_window_exceeded, status: 400} =
               Error.from_stream(%{"code" => 400, "message" => "maximum context length is 8192"})
    end
  end

  test "context_window_exceeded?/1 recognizes the overflow kind only" do
    assert LLM.context_window_exceeded?(Error.new(:context_window_exceeded))
    refute LLM.context_window_exceeded?(Error.new(:invalid_request))
    refute LLM.context_window_exceeded?(:context_window_exceeded)
    refute LLM.context_window_exceeded?({:context_window_exceeded, %{}})
  end

  test "new/2 describes the kind unless given a message" do
    assert %Error{message: "The provider is overloaded"} = Error.new(:overloaded)
    assert %Error{message: "custom"} = Error.new(:unknown, message: "custom")

    assert_raise Error, "The provider rejected the credentials (HTTP 401)", fn ->
      raise Error.new(:auth, status: 401)
    end
  end
end
