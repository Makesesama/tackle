# Run from apps/tackle_cli: MIX_ENV=test mix run --no-start bench/conversation.exs
# Synthetic warmed probes, not terminal latency or CPU profiles. No credentials.
alias ExRatatui.Layout.Rect
alias Tackle.CLI.TUI.Conversation
alias Tackle.CLI.TUI.State.Stream
alias Tackle.CLI.Widgets.Conversation, as: Widget
alias Tackle.Lib.{Message, State}

defmodule ConversationProbe do
  def state(messages, source) do
    %{
      agent_state: %State{messages: messages},
      pending_prompt: nil,
      stream: %Stream{timeline: [%{kind: :assistant, content: source}]},
      thinking_expanded?: false,
      error: nil
    }
  end

  def measure(label, fun) do
    for _ <- 1..5, do: fun.()

    samples =
      for _ <- 1..40 do
        {us, _} = :timer.tc(fun)
        us
      end
      |> Enum.sort()

    IO.puts("#{label}: p50=#{Enum.at(samples, 20)} µs, p95=#{Enum.at(samples, 37)} µs")
  end
end

IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}")
rect = %Rect{width: 80, height: 24}
code = String.duplicate("def hello(name), do: IO.puts(name)\n", 1_515)

for {label, source} <- [
      {"50 KB prose", String.duplicate("A **bold** sentence with `inline` code.\n\n", 1_250)},
      {"50 KB open fence", "```elixir\n" <> code},
      {"50 KB closed fence + prose", "```elixir\n" <> code <> "```\n\nTail"}
    ] do
  state = ConversationProbe.state([], source)
  old = Conversation.new(rect) |> Conversation.refresh(state)
  changed = ConversationProbe.state([], source <> " appended")
  updated = Conversation.refresh(old, changed, [:turn])
  fresh = Conversation.new(rect) |> Conversation.refresh(changed)
  true = updated.content_height == fresh.content_height

  true =
    Widget.render(Conversation.widget(updated), rect) ==
      Widget.render(Conversation.widget(fresh), rect)

  ConversationProbe.measure("#{label} refresh", fn ->
    Conversation.refresh(old, changed, [:turn])
  end)

  ConversationProbe.measure("#{label} paint", fn ->
    Widget.render(Conversation.widget(updated), rect)
  end)
end

for count <- [0, 100, 1_000, 5_000] do
  messages = for i <- 1..count//1, do: Message.assistant(content: "Settled #{i}: **short** text.")
  state = ConversationProbe.state(messages, "Live tail.")
  old = Conversation.new(rect) |> Conversation.refresh(state)
  changed = ConversationProbe.state(messages, "Live tail. Added.")

  ConversationProbe.measure("#{count} history, unchanged turn", fn ->
    Conversation.refresh(old, state, [:turn])
  end)

  ConversationProbe.measure("#{count} history, changed turn", fn ->
    Conversation.refresh(old, changed, [:turn])
  end)

  ConversationProbe.measure("#{count} history, scroll", fn -> Conversation.scroll(old, -3) end)
end
