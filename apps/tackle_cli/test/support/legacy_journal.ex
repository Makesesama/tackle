defmodule Tackle.CLI.Test.LegacyJournal do
  @moduledoc false

  # Writes a session journal as earlier versions left it after
  # `Tackle.Session.Journal.close_journal/1`: one settled turn, then
  # `session.closed`. The items are written with `:disk_log` directly, since
  # the journal no longer writes `session.closed`, and in the shape of their
  # time: no "tree" in `session.created`, no parent links, no content parts.

  alias Tackle.Session.Log
  alias Tackle.Session.Storage

  @written_at "2026-01-01T00:00:00Z"

  @doc "Writes a closed session for `model_ref` in `cwd`'s project and returns its id."
  def write_closed!(home, cwd, model_ref, prompt, answer) do
    session_id = "legacy-#{System.unique_integer([:positive])}"
    {:ok, dir} = Storage.ensure_session_dir(session_id, home: home, cwd: cwd)

    {:ok, log} =
      :disk_log.open(
        name: {:tackle_cli_legacy_journal, session_id},
        file: String.to_charlist(Path.join(dir, "session.dlog")),
        type: :halt,
        format: :internal,
        mode: :read_write,
        repair: false,
        notify: false,
        size: :infinity
      )

    session_id
    |> items(cwd, model_ref, prompt, answer)
    |> Enum.each(&(:ok = :disk_log.log(log, &1)))

    :ok = :disk_log.sync(log)
    :ok = :disk_log.close(log)
    session_id
  end

  defp items(session_id, cwd, model_ref, prompt, answer) do
    header = Log.header(session_id: session_id, created_at: @written_at, cwd: cwd, parent: nil)

    events = [
      {nil,
       Log.event("session.created", %{
         "cwd" => cwd,
         "model_ref" => model_ref,
         "thinking" => nil,
         "title" => nil,
         "tags" => []
       })},
      {"turn-1",
       Log.event("turn.started", %{
         "turn_id" => "turn-1",
         "operation" => "run",
         "input" => prompt,
         "started_at" => @written_at
       })},
      {"turn-1", Log.event("message.appended", %{"message" => message("u1", "user", prompt)})},
      {"turn-1",
       Log.event("message.appended", %{"message" => message("a1", "assistant", answer)})},
      {"turn-1",
       Log.event("turn.completed", %{"turn_id" => "turn-1", "settled_at" => @written_at})},
      {nil, Log.event("session.closed", %{"closed_at" => @written_at})}
    ]

    commits =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {{turn_id, event}, seq} ->
        Log.commit(
          session_id: session_id,
          seq: seq,
          commit_id: "#{session_id}-#{seq}",
          written_at: @written_at,
          turn_id: turn_id,
          events: [event]
        )
      end)

    [header | commits]
  end

  defp message(id, role, content) do
    %{
      "id" => id,
      "role" => role,
      "content" => content,
      "thinking" => nil,
      "tool_calls" => [],
      "tool_call_id" => nil,
      "tool_name" => nil,
      "timestamp" => @written_at,
      "token_usage" => nil,
      "model" => nil,
      "provider_state" => nil
    }
  end
end
