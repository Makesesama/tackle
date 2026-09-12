defmodule Tackle.CLI.TUI.ModulesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Compaction, as: TUICompaction
  alias Tackle.CLI.TUI.{Composer, Inspector, Menu, State, Util, Viewport}
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.{Message, ModelInfo, Usage}
  alias Tackle.Lib.State, as: AgentState

  # The extracted modules take and return `Tackle.CLI.TUI.State`, so most of
  # them can be driven without a running ExRatatui app. These tests cover the
  # pure seams directly; `tui_test.exs` keeps covering the same behaviour
  # through the live shell.

  describe "Util" do
    test "clamp/3 bounds both ends" do
      assert Util.clamp(5, 0, 10) == 5
      assert Util.clamp(-1, 0, 10) == 0
      assert Util.clamp(11, 0, 10) == 10
    end

    test "truncate/2 never exceeds the width budget" do
      assert Util.truncate("hello", 10) == "hello"
      assert Util.truncate("hello world", 5) == "hell…"
      assert String.length(Util.truncate("hello world", 1)) == 1
    end

    test "format_reason/1 renders strings verbatim and other terms inspected" do
      assert Util.format_reason("boom") == "boom"
      assert Util.format_reason({:invalid_new_session, :nope}) == "{:invalid_new_session, :nope}"
    end

    test "copy_notice/3 reports the clipboard writer outcome" do
      ok = %State{clipboard_writer: fn _content -> :ok end}
      assert Util.copy_notice(ok, "text", "Copied") == "Copied"

      failing = %State{clipboard_writer: fn _content -> {:error, :no_clipboard} end}
      assert Util.copy_notice(failing, "text", "Copied") == "Copy failed: :no_clipboard"
    end
  end

  describe "State accessors" do
    test "model_ref/1 prefers the selection ref and falls back to the model" do
      assert State.model_ref(agent_state()) == "openai-codex/test-model"

      assert State.model_ref(%{AgentState.new() | llm: nil, model: "plain"}) == "plain"
      assert State.model_ref(%{AgentState.new() | llm: nil, model: nil}) == nil
    end

    test "model_info/1 returns metadata only when it is present" do
      info = %ModelInfo{model: "test-model", context_window: 1_000}
      assert State.model_info(%{agent_state() | llm: %{selection() | model_info: info}}) == info
      assert State.model_info(%{AgentState.new() | llm: nil}) == nil
    end

    test "latest_usage/1 finds the newest assistant usage" do
      messages = [
        Message.assistant(content: "old", token_usage: %{input_tokens: 1, output_tokens: 1}),
        Message.user("hi"),
        Message.assistant(content: "new", token_usage: %{input_tokens: 5, output_tokens: 2})
      ]

      assert %Usage{input_tokens: 5, output_tokens: 2} =
               State.latest_usage(%{agent_state() | messages: messages})

      assert State.latest_usage(%{agent_state() | messages: [Message.user("hi")]}) == nil
    end

    test "available_models/2 keeps the current model visible" do
      state = agent_state()

      assert State.available_models([models: ["a/one", "openai-codex/test-model"]], state) ==
               ["a/one", "openai-codex/test-model"]

      assert State.available_models([], state) == ["openai-codex/test-model"]

      assert State.available_models([models: ["a/one"]], state) ==
               ["openai-codex/test-model", "a/one"]
    end
  end

  describe "Menu items" do
    test "model rows search the provider, the qualified ref, and the bare id" do
      state = %State{agent_state: agent_state(), models: ["openai-codex/test-model"]}

      assert [
               %{
                 id: "openai-codex/test-model",
                 primary: "test-model",
                 secondary: "[openai-codex]",
                 marker: "✓",
                 search: "openai-codex openai-codex/test-model test-model"
               }
             ] = Menu.items(:model, state)
    end

    test "reasoning rows describe each level and mark the current one" do
      state = %State{agent_state: agent_state()}

      assert [%{id: "off", primary: "off", secondary: "No reasoning", marker: "✓"} | _rest] =
               Menu.items(:thinking, state)
    end

    test "the settings menu has no rows yet" do
      assert Menu.items(:settings, %State{agent_state: agent_state()}) == []
    end
  end

  describe "Viewport" do
    test "update_draft/1 tracks logical lines and emptiness" do
      state = %State{input: Tackle.CLI.Widgets.Input.new()}

      :ok = Tackle.CLI.Widgets.Input.insert_str(state.input, "one\ntwo")
      state = Viewport.update_draft(state)

      assert state.draft_lines == 2
      refute state.draft_empty?

      :ok = Tackle.CLI.Widgets.Input.set_value(state.input, "   \n")
      state = Viewport.update_draft(state)

      assert state.draft_lines == 2
      assert state.draft_empty?
    end

    test "scroll/2 moves the transcript and pauses following" do
      state = shell_state()
      state = %{state | conversation: %{state.conversation | content_height: 200}}

      scrolled = Viewport.scroll(state, 5)

      assert scrolled.conversation.scroll_offset > 0
      assert scrolled.conversation.follow? == false
    end

    test "scroll_reply/2 suppresses a render when the transcript did not move" do
      state = shell_state()

      assert {:noreply, ^state, [render?: false]} = Viewport.scroll_reply(state, state)
    end
  end

  describe "Composer" do
    test "paste/2 normalizes line endings and never submits" do
      state = shell_state()

      state = Composer.paste(state, "a\r\nb\rc")

      assert Tackle.CLI.Widgets.Input.get_value(state.input) == "a\nbc"
      assert state.draft_lines == 2
      refute state.draft_empty?
      assert state.active_turn == nil
    end
  end

  describe "Inspector" do
    test "scroll/2 clamps a wheel delta into the content range" do
      inspector = %{content_height: 30, viewport_height: 10, scroll_offset: 0, notice: "Copied"}
      state = %State{overlay: {:inspector, inspector}}

      state = Inspector.scroll(state, 100)
      assert {:inspector, %{scroll_offset: 20, notice: nil}} = state.overlay

      state = Inspector.scroll(state, -100)
      assert {:inspector, %{scroll_offset: 0}} = state.overlay
    end
  end

  defp selection do
    %Selection{
      adapter: __MODULE__,
      adapter_id: "openai-codex",
      model: "test-model",
      ref: "openai-codex/test-model"
    }
  end

  describe "Compaction" do
    test "request/1 refuses while a turn or another operation is active" do
      busy = %State{active_turn: %{id: "turn-1"}}
      assert {:noreply, refused} = TUICompaction.request(busy)
      assert refused.notice =~ "when idle"

      pending = %State{pending_operation: %{ref: make_ref(), kind: :submit}}
      assert {:noreply, waiting} = TUICompaction.request(pending)
      assert waiting.notice =~ "Wait for the current operation"
    end

    test "notice/1 summarises the shrink and falls back safely" do
      record = %{
        tokens_before: 1_200,
        estimated_tokens_after: 300,
        shadowed_message_ids: ["a", "b"]
      }

      assert TUICompaction.notice(record) ==
               "Compacted 2 messages · 1.2k → 300 est. tokens"

      assert TUICompaction.notice(%{}) == "Compacted context"
      assert TUICompaction.notice(nil) == "Compacted context"
    end

    test "activity/1 maps lifecycle events to status words" do
      assert TUICompaction.activity({:compaction_start, %{}}) == "compacting"
      assert TUICompaction.activity({:compaction_retry, %{}}) == "compacting"
      assert TUICompaction.activity({:compaction_end, %{status: :completed}}) == "compacted"

      assert TUICompaction.activity({:compaction_end, %{status: :cancelled}}) ==
               "compaction cancelled"

      assert TUICompaction.activity({:compaction_end, %{status: :failed}}) == "compaction failed"
    end
  end

  defp agent_state do
    %{AgentState.new() | llm: selection(), model: "test-model"}
  end

  defp shell_state do
    %State{
      input: Tackle.CLI.Widgets.Input.new(),
      agent_state: agent_state(),
      conversation: Viewport.new_conversation(80, 24),
      size: {80, 24},
      draft_lines: 1,
      draft_empty?: true
    }
  end
end
