defmodule Tackle.Web.ChatStoreTest do
  # The store is a singleton above the LiveViews, so its tests share it with
  # anything else running.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Web.ChatFixture
  alias Tackle.Web.ChatStore

  @slug "local-widgets-1a2b3c"

  setup do
    ChatFixture.setup()
  end

  describe "creating a conversation" do
    test "records the directory, the model and an empty transcript", %{cwd: cwd} do
      assert {:ok, conversation} =
               ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      assert conversation.cwd == cwd
      assert conversation.model == "fake/echo"
      assert conversation.messages == []
      assert conversation.title == "New chat"
      assert ChatStore.get(conversation.id) == conversation
    end

    test "expands a relative directory", %{cwd: cwd} do
      relative = Path.relative_to(cwd, File.cwd!())

      assert {:ok, conversation} =
               ChatStore.create(project_slug: @slug, cwd: relative, model: "fake/echo")

      assert conversation.cwd == cwd
    end

    test "refuses a directory that is not there", %{root: root} do
      missing = Path.join(root, "not-created")

      assert {:error, {:workspace_missing, ^missing}} =
               ChatStore.create(project_slug: @slug, cwd: missing, model: "fake/echo")
    end

    test "refuses anything that is not a directory path" do
      assert {:error, {:invalid_workspace, nil}} =
               ChatStore.create(project_slug: @slug, model: "fake/echo")

      assert {:error, {:invalid_workspace, 42}} =
               ChatStore.create(project_slug: @slug, cwd: 42, model: "fake/echo")
    end
  end

  describe "the transcript" do
    test "the first question names the conversation", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      :ok = ChatStore.append_message(conversation.id, Message.user("Why does it spin?\nMore."))

      assert ChatStore.get(conversation.id).title == "Why does it spin?"

      # A later question does not rename a conversation the reader is returning to.
      :ok = ChatStore.append_message(conversation.id, Message.user("And now?"))
      assert ChatStore.get(conversation.id).title == "Why does it spin?"
    end

    test "a long first question is shortened to fit a list entry", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      question = String.duplicate("a", 200)

      :ok = ChatStore.append_message(conversation.id, Message.user(question))

      title = ChatStore.get(conversation.id).title
      assert String.length(title) == 60
      assert title == String.slice(question, 0, 60)
    end

    test "a blank question leaves the title alone", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      :ok = ChatStore.append_message(conversation.id, Message.user("   \n  "))

      assert ChatStore.get(conversation.id).title == "New chat"
    end

    test "the transcript can be replaced with a settled one", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      settled = [Message.user("Question"), Message.assistant(content: "Answer")]

      :ok = ChatStore.put_messages(conversation.id, settled)

      assert ChatStore.get(conversation.id).messages == settled
    end

    test "an unknown conversation is nil rather than an error" do
      assert ChatStore.get("no-such-conversation") == nil
    end

    test "writing to an unknown conversation is ignored" do
      assert :ok = ChatStore.append_message("gone", Message.user("Hello"))
      assert :ok = ChatStore.put_messages("gone", [])
      assert :ok = ChatStore.set_model("gone", "fake/echo")
      assert ChatStore.get("gone") == nil
    end
  end

  describe "the model" do
    test "can be changed without changing the conversation", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      :ok = ChatStore.append_message(conversation.id, Message.user("Hello"))

      :ok = ChatStore.set_model(conversation.id, "fake/echo-2")

      stored = ChatStore.get(conversation.id)
      assert stored.model == "fake/echo-2"
      assert Enum.map(stored.messages, & &1.role) == [:user]
    end
  end

  describe "listing" do
    test "counts the messages without returning them", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      :ok = ChatStore.append_message(conversation.id, Message.user("Hello"))

      summary = summary_of(conversation.id)

      assert summary.message_count == 1
      assert summary.title == "Hello"
      refute Map.has_key?(summary, :messages)
    end

    test "puts the most recently written conversation first", %{cwd: cwd} do
      {:ok, first} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, second} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      # Both conversations exist by now, so the update below is what has to put
      # the first one back at the top.
      Process.sleep(2)
      :ok = ChatStore.append_message(first.id, Message.user("Back to the first"))

      ids = Enum.map(ChatStore.list(@slug), & &1.id)
      assert first.id in ids
      assert second.id in ids
      assert position(ids, first.id) < position(ids, second.id)
    end
  end

  describe "deleting" do
    test "forgets the conversation", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      assert :ok = ChatStore.delete(conversation.id)

      assert ChatStore.get(conversation.id) == nil
      refute Enum.any?(ChatStore.list(@slug), &(&1.id == conversation.id))
    end

    test "an unknown conversation is not an error" do
      assert :ok = ChatStore.delete("never-existed")
    end
  end

  describe "subscribers" do
    test "are told when a conversation is created, changed and deleted", %{cwd: cwd} do
      :ok = ChatStore.subscribe()

      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      assert_receive {:chat_updated, id}
      assert id == conversation.id

      :ok = ChatStore.append_message(id, Message.user("Hello"))
      assert_receive {:chat_updated, ^id}

      :ok = ChatStore.delete(id)
      assert_receive {:chat_deleted, ^id}
    end

    test "are not told about writes to an unknown conversation" do
      :ok = ChatStore.subscribe()

      :ok = ChatStore.append_message("gone", Message.user("Hello"))

      refute_receive {:chat_updated, _id}
    end
  end

  defp summary_of(id), do: Enum.find(ChatStore.list(@slug), &(&1.id == id))

  defp position(ids, id), do: Enum.find_index(ids, &(&1 == id))
end
