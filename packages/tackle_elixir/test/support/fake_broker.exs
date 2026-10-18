# A misbehaving broker for protocol tests: `elixir fake_broker.exs MODE`.
io = Port.open({:fd, 0, 1}, [:binary, :eof])

frame = fn term ->
  payload = :erlang.term_to_binary(term)
  <<byte_size(payload)::32, payload::binary>>
end

read_request = fn ->
  receive do
    {^io, {:data, <<_size::32, payload::binary>>}} -> :erlang.binary_to_term(payload)
  end
end

case System.argv() do
  ["bad_version"] ->
    Port.command(io, frame.({:hello, 99}))

  ["garbage"] ->
    Port.command(io, <<5::32, "hello">>)

  ["huge"] ->
    Port.command(io, <<0x7FFFFFFF::32, "x">>)

  ["silent"] ->
    :ok

  ["second_hello"] ->
    Port.command(io, frame.({:hello, 1}))
    Port.command(io, frame.({:hello, 1}))

  ["bad_result"] ->
    Port.command(io, frame.({:hello, 1}))
    {:request, id, _op} = read_request.()
    Port.command(io, frame.({:reply, id, {:ok, %{status: :ok, diagnostics: [], output: ""}}}))
end

receive do
  {^io, :eof} -> :ok
end
