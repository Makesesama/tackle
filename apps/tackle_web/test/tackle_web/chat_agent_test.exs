defmodule Tackle.Web.ChatAgentTest do
  # The adapter list, the default model and TACKLE_HOME are global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Tools.Bash
  alias Tackle.Tools.Read
  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatFixture

  setup do
    ChatFixture.setup()
  end

  describe "the agent a conversation runs" do
    test "is the harness's own agent: its tools, its prompt, its working directory", %{cwd: cwd} do
      assert {:ok, %State{} = state} = ChatAgent.new(cwd: cwd)

      assert Read in state.tools
      assert Bash in state.tools
      assert state.context.cwd == cwd
      assert state.system_prompt =~ "Current working directory: #{cwd}"
      assert state.llm.model == "echo"
    end

    test "resumes a stored transcript", %{cwd: cwd} do
      messages = [Message.user("Hello"), Message.assistant(content: "Hi")]

      assert {:ok, %State{messages: ^messages}} = ChatAgent.new(cwd: cwd, messages: messages)
    end

    test "a transcript can be installed on an already built agent", %{cwd: cwd} do
      {:ok, state} = ChatAgent.new(cwd: cwd)
      messages = [Message.user("Hello"), Message.assistant(content: "Hi")]

      resumed = ChatAgent.with_messages(state, messages)

      assert resumed.messages == messages
    end

    test "starts with no transcript when none is stored", %{cwd: cwd} do
      assert {:ok, %State{messages: []}} = ChatAgent.new(cwd: cwd)
    end
  end

  describe "the models" do
    test "come from the configured adapters" do
      assert ChatAgent.models() == ["fake/echo", "fake/echo-2"]
      assert ChatAgent.default_model() == "fake/echo"
    end

    test "an unknown one is reported rather than substituted", %{cwd: cwd} do
      assert {:error, {:unknown_model, "fake/nope"}} =
               ChatAgent.new(cwd: cwd, model: "fake/nope")
    end
  end

  describe "the working directory" do
    test "defaults to the directory the frontend runs in" do
      Application.delete_env(:tackle_web, :chat_cwd)

      assert ChatAgent.default_cwd() == File.cwd!()
    end

    test "can be configured", %{cwd: cwd} do
      Application.put_env(:tackle_web, :chat_cwd, cwd)

      assert ChatAgent.default_cwd() == cwd
    end

    test "a directory that is not there is reported", %{root: root} do
      missing = Path.join(root, "not-created")

      assert {:error, {:invalid_option, :cwd, _reason}} = ChatAgent.new(cwd: missing)
    end
  end
end
