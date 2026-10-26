defmodule Tackle.Session.InboxTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope
  alias Tackle.Session.Inbox

  @agent AgentRef.new!("scope", "agent")

  defp message(text) do
    {:ok, envelope} = Envelope.new(:message, @agent, text)
    envelope
  end

  defp launch(turn_id, call_id) do
    {:ok, envelope} =
      Envelope.new(:launch, @agent, "started #{call_id}", %{
        turn_id: turn_id,
        tool_call_id: call_id
      })

    envelope
  end

  defp completion(text) do
    {:ok, envelope} = Envelope.new(:completion, @agent, text)
    envelope
  end

  defp push!(inbox, %Envelope{} = envelope) do
    {:ok, inbox} = Inbox.push(inbox, envelope)
    inbox
  end

  defp push!(inbox, text) when is_binary(text) do
    {:ok, inbox} = Inbox.push_user(inbox, text)
    inbox
  end

  defp inbox(entries), do: Enum.reduce(entries, Inbox.new(), &push!(&2, &1))

  describe "push" do
    test "holds user input and envelopes as one entry type, oldest first" do
      note = message("note")
      inbox = inbox(["first", note])

      assert Inbox.entries(inbox) == [
               %Envelope{kind: :message, from: :user, message: "first"},
               note
             ]
    end

    test "rebuilds envelopes, so a hand-built one cannot pass as the user" do
      spoofed = %Envelope{kind: :message, from: :user, message: "rm -rf"}

      assert {:error, {:invalid_envelope, :message, :user, "rm -rf", nil}} =
               Inbox.push(Inbox.new(), spoofed)

      assert {:error, {:invalid_envelope, :launch, @agent, "x", nil}} =
               Inbox.push(Inbox.new(), %Envelope{kind: :launch, from: @agent, message: "x"})
    end

    test "bounds ordinary messages and deferred notices separately" do
      full = inbox(Enum.map(1..16, &"user #{&1}") ++ Enum.map(1..16, &message("agent #{&1}")))

      assert {:error, :inbox_full} = Inbox.push_user(full, "one more")
      assert {:error, :inbox_full} = Inbox.push(full, message("one more"))
      assert {:ok, with_notice} = Inbox.push(full, completion("done"))

      deferred = inbox(Enum.map(1..128, &launch("turn", "call-#{&1}")))
      assert {:error, :deferred_inbox_full} = Inbox.push(deferred, completion("done"))
      assert {:ok, _inbox} = Inbox.push_user(deferred, "still fits")
      assert Enum.count(Inbox.entries(with_notice)) == 33
    end

    test "bounds the bytes of all entries together" do
      big = String.duplicate("x", 9 * 1024 * 1024)
      inbox = inbox([big, message(big)])

      assert {:error, :inbox_full} = Inbox.push_user(inbox, big)
      assert {:error, :deferred_inbox_full} = Inbox.push(inbox, completion(big))

      {:ok, inbox} = Inbox.withdraw(inbox, big)
      assert {:ok, _inbox} = Inbox.push_user(inbox, big)
    end
  end

  describe "withdraw" do
    test "removes the newest matching user message only" do
      note = message("same")
      inbox = inbox(["same", note, "other", "same"])

      assert {:ok, inbox} = Inbox.withdraw(inbox, "same")

      assert Inbox.entries(inbox) == [
               %Envelope{kind: :message, from: :user, message: "same"},
               note,
               %Envelope{kind: :message, from: :user, message: "other"}
             ]

      assert {:ok, inbox} = Inbox.withdraw(inbox, "same")
      assert {:error, :not_queued} = Inbox.withdraw(inbox, "same")
    end

    test "is refused while a reservation is open, even for later input" do
      {_entries, inbox} = inbox(["reserved"]) |> Inbox.reserve()
      inbox = push!(inbox, "later")

      assert {:error, :reserved} = Inbox.withdraw(inbox, "reserved")
      assert {:error, :reserved} = Inbox.withdraw(inbox, "later")
      assert {:ok, _inbox} = inbox |> Inbox.release() |> Inbox.withdraw("later")
    end
  end

  describe "delivery" do
    test "takes deliverable entries and keeps held launches" do
      held = launch("turn", "call")
      note = message("note")
      inbox = inbox([held, "typed", note])

      assert Inbox.pending?(inbox)
      assert {[typed, ^note], rest} = Inbox.take_deliverable(inbox)
      assert typed == %Envelope{kind: :message, from: :user, message: "typed"}
      assert Inbox.entries(rest) == [held]
      refute Inbox.pending?(rest)
    end

    test "names the reason an inbox starts a turn" do
      assert Inbox.turn_reason(inbox([completion("done"), launch("t", "c")])) ==
               :background_notice

      assert Inbox.turn_reason(inbox([completion("done"), "typed"])) == :queued_messages
      assert Inbox.turn_reason(inbox([message("note")])) == :queued_messages
    end

    test "discards only the launches whose tool call reported in that turn" do
      reported = launch("turn", "reported")
      cut_off = launch("turn", "cut-off")
      other_turn = launch("other", "reported")
      inbox = inbox([reported, cut_off, other_turn, "typed"])

      inbox = Inbox.discard_reported_launches(inbox, "turn", MapSet.new(["reported"]))

      assert Inbox.entries(inbox) == [
               cut_off,
               other_turn,
               %Envelope{kind: :message, from: :user, message: "typed"}
             ]
    end
  end

  describe "reservation" do
    test "commits the reserved prefix and keeps entries pushed since" do
      {reserved, inbox} = inbox(["one", "two"]) |> Inbox.reserve()
      inbox = push!(inbox, "three")

      assert Inbox.user_messages(reserved) == ["one", "two"]
      assert {committed, inbox} = Inbox.commit_reserved(inbox)
      assert Inbox.user_messages(committed) == ["one", "two"]
      assert Inbox.user_messages(Inbox.entries(inbox)) == ["three"]
      assert {:ok, _inbox} = Inbox.withdraw(inbox, "three")
    end

    test "commits only the entries that reached the conversation" do
      {_reserved, inbox} = inbox(["one", "two", "three"]) |> Inbox.reserve()

      assert {committed, inbox} = Inbox.commit_reserved(inbox, 1)
      assert Inbox.user_messages(committed) == ["one"]
      assert Inbox.user_messages(Inbox.entries(inbox)) == ["two", "three"]
    end

    test "a released reservation keeps every entry" do
      {_reserved, reserved} = inbox(["one"]) |> Inbox.reserve()
      released = Inbox.release(reserved)

      assert Inbox.entries(released) == Inbox.entries(reserved)
      assert {:ok, _inbox} = Inbox.withdraw(released, "one")
    end
  end

  describe "projection" do
    test "labels agent messages and leaves user input as written" do
      inbox = inbox(["typed", message("note")])

      assert Enum.map(Inbox.entries(inbox), &Inbox.content/1) == [
               "typed",
               "Message from agent agent:\n\nnote"
             ]

      {agent_state, messages} = Inbox.project(Inbox.entries(inbox), AgentState.new())

      assert Enum.map(messages, &{&1.role, &1.content}) == [
               {:user, "typed"},
               {:user, "Message from agent agent:\n\nnote"}
             ]

      assert agent_state.messages == messages
    end

    test "reports one received event per agent entry" do
      owner = AgentRef.new!("scope", "owner")
      entries = Inbox.entries(inbox(["typed", message("note"), completion("done")]))

      assert [
               %Event{
                 type: :subagent_message_received,
                 data: %{from_agent_ref: @agent, agent_ref: ^owner}
               },
               %Event{type: :subagent_message_received}
             ] = Inbox.drained_events(entries, owner)
    end
  end
end
