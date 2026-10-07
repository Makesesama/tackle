# Run from apps/tackle_cli: MIX_ENV=test mix run --no-start bench/conversation_native.exs
# Warmed synthetic stage probes. No credentials, real tty, or dependency changes.
# Wall time includes synchronous native execution, scheduler waits, and copying.
# No native allocation/CPU profiling: BEAM memory and reductions cannot measure it.
alias ExRatatui.{CodeBlock, Layout.Rect, Session}
alias ExRatatui.Native, as: ExNative
alias Tackle.CLI.Native
alias Tackle.CLI.TUI.CodeFences
alias Tackle.CLI.Widgets.{Conversation, Surface}

defmodule NativeConversationProbe do
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

  # Same owned-row conversion as Widgets.Conversation's code-cell path.
  def wire_rows(lines) do
    Enum.map(lines, fn line ->
      {Enum.map(line.spans, fn span ->
         {String.trim_trailing(span.content, "\n"), Conversation.style(%{span.style | bg: nil})}
       end), Conversation.style(%{line.style | bg: nil})}
    end)
  end
end

alias NativeConversationProbe, as: Probe

IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}")
IO.puts("Stage timings include NIF scheduling/term conversion, not just Rust CPU time.")
rect = %Rect{width: 80, height: 24}
base = {nil, nil, nil, 0}
marker = {"●", base}
code = String.duplicate("def hello(name), do: IO.puts(name)\n", 1_515)
fence = "```elixir\n" <> code
raw = ExNative.highlight_code(code, "elixir", "base16-ocean.dark")
lines = CodeBlock.from_native(raw)
rows = Probe.wire_rows(lines)

Probe.measure("50 KB open fence / split", fn -> CodeFences.split(fence) end)

Probe.measure("50 KB code / native highlight + return terms", fn ->
  ExNative.highlight_code(code, "elixir", "base16-ocean.dark")
end)

Probe.measure("50 KB code / returned terms -> Line structs", fn ->
  CodeBlock.from_native(raw)
end)

Probe.measure("50 KB code / Line structs -> Tackle wire rows", fn ->
  Probe.wire_rows(lines)
end)

Probe.measure("50 KB code / native cell layout", fn ->
  Native.conversation_code(rows, rect.width, base, marker, "elixir")
end)

for {label, source} <- [
      {"short paragraphs",
       String.duplicate("A **bold** sentence with `inline` code.\n\n", 1_250)},
      {"one paragraph", String.duplicate("A **bold** sentence with `inline` code. ", 1_250)}
    ] do
  Probe.measure("50 KB #{label} / native parse + measure", fn ->
    Native.conversation_message(source, rect.width, true, base, marker)
  end)

  {cell, height} = Native.conversation_message(source, rect.width, true, base, marker)
  {resource, ^height} = Native.conversation_new([cell], rect.width)

  for {position, offset} <- [{"top", 0}, {"bottom", max(height - rect.height, 0)}] do
    render = fn ->
      Native.conversation_render(resource, rect.width, rect.height, offset, [], base, nil)
    end

    Probe.measure("50 KB #{label} / native paint #{position} + return rows", render)
  end
end

{cell, height} = Native.conversation_code(rows, rect.width, base, marker, "elixir")
{resource, ^height} = Native.conversation_new([cell], rect.width)
offset = max(height - rect.height, 0)
paint = fn top -> Native.conversation_render(resource, 80, 24, top, [], base, nil) end
{:ok, painted} = paint.(offset)

{:ok, selected} =
  Native.conversation_render(resource, 80, 24, offset, [0], {nil, 6, nil, 0}, nil)

placed = Surface.place(painted, rect)
encoded = Enum.map(placed, &ExRatatui.encode_command/1)

Probe.measure("80x24 code / native paint + return rows", fn -> paint.(offset) end)
Probe.measure("80x24 code / Surface.place", fn -> Surface.place(painted, rect) end)

Probe.measure("80x24 code / ExRatatui encode", fn ->
  Enum.map(placed, &ExRatatui.encode_command/1)
end)

session = Session.new(80, 24)

try do
  Probe.measure("80x24 code / native draw unchanged + drain ANSI", fn ->
    :ok = ExNative.session_draw(session.ref, encoded)
    Session.take_output(session)
  end)

  # Toggle selection: an unchanged-buffer diff alone understates output cost.
  # Highlighting is outside timing; both frames go through the full bridge.
  alternate = Surface.place(selected, rect)
  true = placed != alternate
  cursor = :atomics.new(1, [])

  Probe.measure("80x24 code / bridge + changed draw + drain ANSI", fn ->
    widgets = if rem(:atomics.add_get(cursor, 1, 1), 2) == 0, do: placed, else: alternate
    :ok = Session.draw(session, widgets)
    output = Session.take_output(session)
    true = byte_size(output) > 0
  end)
after
  :ok = Session.close(session)
end
