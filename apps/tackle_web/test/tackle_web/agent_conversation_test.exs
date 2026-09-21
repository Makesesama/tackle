defmodule Tackle.Web.AgentConversationTest do
  # The conversation root is global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Web.AgentConversation
  alias Tackle.Web.GitFixture

  setup do
    root = GitFixture.scratch_dir("conversations")
    previous = Application.get_env(:tackle_web, :conversations_root)

    Application.put_env(:tackle_web, :conversations_root, root)

    on_exit(fn ->
      restore(:conversations_root, previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "the key identifies the pull request a conversation belongs to" do
    assert AgentConversation.key("github-hexpm-hexpm-9a1b2c", "pr-1923") ==
             "github-hexpm-hexpm-9a1b2c#pr-1923"
  end

  test "a stored conversation round-trips with its anchors" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    anchor = {"lib/widget.ex", :new, 12}

    messages = [
      Message.user("Why is this here?"),
      Message.assistant(content: "Because the widget needs it.")
    ]

    assert :ok = AgentConversation.save(path, messages, %{"q1" => anchor, "q2" => :general})

    assert %{messages: restored, anchors: anchors} = AgentConversation.load(path)
    assert Enum.map(restored, & &1.role) == [:user, :assistant]
    assert Enum.map(restored, & &1.content) == Enum.map(messages, & &1.content)
    assert anchors == %{"q1" => anchor, "q2" => :general}
  end

  test "a range anchor round-trips with both ends" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    anchor = {"lib/widget.ex", :new, 12, 15}

    assert :ok =
             AgentConversation.save(path, [Message.user("Why these lines?")], %{"q1" => anchor})

    assert %{anchors: %{"q1" => ^anchor}} = AgentConversation.load(path)
  end

  test "a transcript written before ranges existed loads its anchor as one line" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    File.mkdir_p!(Path.dirname(path))

    body =
      JSON.encode!(%{
        "version" => 1,
        "messages" => [],
        "anchors" => %{"q1" => %{"path" => "lib/widget.ex", "side" => "old", "line" => 3}}
      })

    File.write!(path, body)

    assert %{anchors: %{"q1" => {"lib/widget.ex", :old, 3}}} = AgentConversation.load(path)
  end

  test "a range with an unusable first line is dropped, like any malformed anchor" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    File.mkdir_p!(Path.dirname(path))

    body =
      JSON.encode!(%{
        "version" => 1,
        "messages" => [],
        "anchors" => %{
          "q1" => %{
            "path" => "lib/widget.ex",
            "side" => "new",
            "line" => 4,
            "from_line" => 0
          }
        }
      })

    File.write!(path, body)

    assert %{anchors: anchors} = AgentConversation.load(path)
    assert anchors == %{}
  end

  test "a restored message keeps its tool call, which is what continuing needs" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")

    call = %{id: "call-1", name: "read", arguments: %{"path" => "lib/widget.ex"}}
    messages = [%Message{id: "a1", role: :assistant, tool_calls: [call]}]

    assert :ok = AgentConversation.save(path, messages)
    assert %{messages: [restored]} = AgentConversation.load(path)
    assert restored.tool_calls == [call]
  end

  test "a missing conversation loads as empty" do
    assert AgentConversation.load(AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")) ==
             AgentConversation.empty()
  end

  test "an unreadable conversation loads as empty rather than raising" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json at all")

    assert AgentConversation.load(path) == AgentConversation.empty()
  end

  test "an unrecognized anchor is dropped without losing the messages" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")
    File.mkdir_p!(Path.dirname(path))

    body =
      JSON.encode!(%{
        "version" => 1,
        "messages" => [Tackle.Session.Codec.encode_message!(Message.user("Kept."))],
        "anchors" => %{
          "q1" => %{"path" => "lib/widget.ex", "side" => "sideways", "line" => 3},
          "q2" => "elsewhere",
          "q3" => %{"path" => "lib/widget.ex", "side" => "old", "line" => 0}
        }
      })

    File.write!(path, body)

    assert %{messages: [%Message{content: "Kept."}], anchors: anchors} =
             AgentConversation.load(path)

    assert anchors == %{}
  end

  test "saving replaces the previous transcript instead of appending" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")

    assert :ok = AgentConversation.save(path, [Message.user("First.")])
    assert :ok = AgentConversation.save(path, [Message.user("Second.")])

    assert %{messages: [%Message{content: "Second."}]} = AgentConversation.load(path)
  end

  test "saving writes no temporary file behind" do
    path = AgentConversation.path("github-acme-widgets-1a2b3c", "pr-7")

    assert :ok = AgentConversation.save(path, [Message.user("Only.")])

    assert Path.wildcard("#{path}.tmp-*") == []
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
