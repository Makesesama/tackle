defmodule Tackle.Lib.Tool.ErrorTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error

  @call %Call{id: "call-1", name: "lookup", arguments: %{}}

  test "interrupted/3 settles a call left without a result when its turn ended" do
    message = "Tool execution was aborted before this call completed."

    assert Error.interrupted("call-1", "lookup", :aborted) == %Error{
             tool_call_id: "call-1",
             name: "lookup",
             reason: :interrupted,
             message: message,
             content: "Error: " <> message,
             details: nil,
             metadata: %{}
           }
  end

  test "interrupted/3 says how the call ended" do
    for outcome <- [:interrupted, :aborted, :cancelled] do
      assert Error.interrupted("call-1", "lookup", outcome).message ==
               "Tool execution was #{outcome} before this call completed."
    end

    assert Error.interrupted("call-1", "lookup", :unknown).message ==
             "Tool execution was interrupted before a result was recorded; the outcome is unknown."
  end

  test "unknown_tool/1 settles a call to a tool the registry does not know" do
    assert Error.unknown_tool(@call) == %Error{
             tool_call_id: "call-1",
             name: "lookup",
             reason: :unknown_tool,
             message: "Unknown tool: lookup",
             content: "Error: Unknown tool: lookup",
             details: nil,
             metadata: %{}
           }
  end

  test "crashed/3 keeps the crash for the host and shows the model a generic error" do
    raised = Error.crashed(@call, :error, %RuntimeError{message: "boom"})

    assert raised.reason == :execution_error
    assert raised.message == "Tool crashed: boom"
    assert raised.content == "Error: The tool failed while completing the request."
    assert raised.details == {:error, %RuntimeError{message: "boom"}}
    assert raised.metadata == %{}

    assert Error.crashed(@call, :throw, :oops).message == "Tool crashed: throw :oops"
    assert Error.crashed(@call, :exit, :killed).message == "Tool crashed: exit :killed"
  end

  @generic "Error: The tool failed while completing the request."

  test "invalid_input/2 shows the model what was wrong with the arguments" do
    message = "Invalid tool arguments: path: is required"

    assert Error.invalid_input(@call, message) == %Error{
             tool_call_id: "call-1",
             name: "lookup",
             reason: :invalid_input,
             message: message,
             content: "Error: " <> message,
             details: nil,
             metadata: %{}
           }
  end

  test "invalid_output/2 keeps the reason for the host and shows the model a generic error" do
    assert %Error{reason: :invalid_output, message: "Invalid tool output: x", details: nil} =
             error = Error.invalid_output(@call, "Invalid tool output: x")

    assert error.content == @generic

    assert %Error{message: "Invalid tool output: {:mismatch, 1}", details: {:mismatch, 1}} =
             error = Error.invalid_output(@call, {:mismatch, 1})

    assert error.content == @generic
  end

  test "failed/2 shows a binary reason to the model and hides any other" do
    assert %Error{reason: :execution_error, message: "no such file", details: "no such file"} =
             error = Error.failed(@call, "no such file")

    assert error.content == "Error: no such file"

    for reason <- [{:secret, "token"}, ""] do
      error = Error.failed(@call, reason)

      assert error.reason == :execution_error
      assert error.message == "Tool execution failed: #{inspect(reason)}"
      assert error.details == reason
      assert error.content == @generic
    end
  end

  test "constructors make the model-facing text valid UTF-8" do
    error = Error.failed(@call, "bad " <> <<255>>)

    assert error.message == "bad \uFFFD"
    assert error.content == "Error: bad \uFFFD"
    assert error.details == "bad " <> <<255>>
  end
end
