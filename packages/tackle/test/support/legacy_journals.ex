defmodule Tackle.Test.LegacyJournals do
  @moduledoc """
  Journals, sidecars, and lock files as earlier versions wrote them.

  Each fixture is built from plain items and written with `:disk_log`
  directly, not through `Tackle.Session.Journal`, so it keeps the shape the
  older version produced even when the current writer would no longer
  produce it:

    * `pre_tree/2`: a linear journal from before conversation trees and
      content parts. `session.created` has no `"tree"`, messages and the
      compaction have no `"parent_id"`, messages have no `"parts"`,
      `session.configuration_changed` records `"thinking" => nil` (the raw,
      unset `:reasoning_effort`), and usage is stored under the
      `Tackle.Lib.Usage` field names with the provider's report under
      `"raw"`.
    * `closed_then_resumed/2`: a turn, a `session.closed` (which
      `Journal.close_journal/1` wrote), and a later turn.
    * `closed_during_turn/2`: a `session.closed` written while a turn ran,
      which left the turn without a terminal event.
    * `forked/3`: a fork, whose header names its parent and whose first
      commit is `session.forked`.

  Tool calls were always written with string keys, so there is no fixture
  with atom keys.
  """

  alias Tackle.Session.Log
  alias Tackle.Session.Storage

  @created_at "2026-01-01T00:00:00Z"
  @model "test/echo"

  @doc "The model every fixture records, the test adapter's."
  def model, do: @model

  @doc """
  Writes `items` (a header, then commits) as the journal of `session_id` at
  `location` (`Tackle.Session.Storage` location options; without `:cwd`, the
  flat layout from before project directories).
  """
  def write!(session_id, location, items) do
    {:ok, dir} = Storage.ensure_session_dir(session_id, location)
    path = Path.join(dir, "session.dlog")

    {:ok, name} =
      :disk_log.open(
        name: {:tackle_legacy_journal, session_id},
        file: String.to_charlist(path),
        type: :halt,
        format: :internal,
        mode: :read_write,
        repair: false,
        notify: false,
        size: :infinity
      )

    Enum.each(items, fn item -> :ok = :disk_log.log(name, item) end)
    :ok = :disk_log.sync(name)
    :ok = :disk_log.close(name)
    path
  end

  @doc """
  A linear journal from before conversation trees: two turns, the first with
  a tool call, then a compaction of the first turn.
  """
  def pre_tree(session_id, cwd \\ nil) do
    first_turn = [
      user("u1", "list the files"),
      assistant("a1", nil,
        tool_calls: [%{"id" => "call-1", "name" => "bash", "arguments" => %{"cmd" => "ls"}}]
      ),
      tool("t1", "call-1", "bash", "README.md")
    ]

    commits(session_id, [
      {nil, [created(cwd, %{"model_ref" => @model, "thinking" => nil})]},
      {nil,
       [
         event("session.configuration_changed", %{
           "model_ref" => @model,
           "thinking" => nil,
           "changed_at" => @created_at
         })
       ]},
      {"turn-1", [turn_started("turn-1", "list the files")]},
      {"turn-1", [appended(Enum.at(first_turn, 0))]},
      {"turn-1", [appended(Enum.at(first_turn, 1))]},
      {"turn-1",
       [
         event("tool.execution_started", %{
           "tool_call_id" => "call-1",
           "name" => "bash",
           "arguments" => %{"cmd" => "ls"},
           "started_at" => @created_at
         })
       ]},
      {"turn-1", [appended(Enum.at(first_turn, 2))]},
      {"turn-1", [appended(assistant("a2", "One file: README.md.", usage: usage()))]},
      {"turn-1", [settled("turn-1")]},
      {"turn-2", [turn_started("turn-2", "thanks")]},
      {"turn-2", [appended(user("u2", "thanks"))]},
      {"turn-2", [appended(assistant("a3", "You are welcome."))]},
      {"turn-2", [compacted(~w(u1 a1 t1 a2), "u2")]},
      {"turn-2", [settled("turn-2")]}
    ])
    |> with_header(session_id, cwd, nil)
  end

  @doc "A turn, a `session.closed` that ended no turn, and a later turn."
  def closed_then_resumed(session_id, cwd \\ nil) do
    commits(session_id, [
      {nil, [created(cwd, %{"model_ref" => @model, "thinking" => "medium"})]},
      {"turn-1", [turn_started("turn-1", "before closing")]},
      {"turn-1", [appended(user("u1", "before closing"))]},
      {"turn-1", [appended(assistant("a1", "closing soon"))]},
      {"turn-1", [settled("turn-1")]},
      {nil, [event("session.closed", %{"closed_at" => @created_at})]},
      {"turn-2", [turn_started("turn-2", "after closing")]},
      {"turn-2", [appended(user("u2", "after closing"))]},
      {"turn-2", [appended(assistant("a2", "still here"))]},
      {"turn-2", [settled("turn-2")]}
    ])
    |> with_header(session_id, cwd, nil)
  end

  @doc """
  A `session.closed` written while a turn ran: the commit carried the turn's
  id and the turn got no terminal event.
  """
  def closed_during_turn(session_id, cwd \\ nil) do
    commits(session_id, [
      {nil, [created(cwd, %{"model_ref" => @model})]},
      {"turn-1", [turn_started("turn-1", "interrupted by close")]},
      {"turn-1", [appended(user("u1", "interrupted by close"))]},
      {"turn-1", [event("session.closed", %{"closed_at" => @created_at})]}
    ])
    |> with_header(session_id, cwd, nil)
  end

  @doc """
  A fork of `parent_id` at its commit `parent_seq`: `session.forked`, then the
  parent's commits renumbered from 2, as `Tackle.Session.Store.fork/2` writes.
  """
  def forked(session_id, parent_id, parent_seq, cwd \\ nil) do
    commits(session_id, [
      {nil,
       [
         event("session.forked", %{
           "parent_session_id" => parent_id,
           "parent_seq" => parent_seq,
           "forked_at" => @created_at
         })
       ]},
      {nil, [created(cwd, %{"model_ref" => @model, "title" => "Forked work"})]},
      {"turn-1", [turn_started("turn-1", "shared start")]},
      {"turn-1", [appended(user("u1", "shared start"))]},
      {"turn-1", [appended(assistant("a1", "shared answer"))]},
      {"turn-1", [settled("turn-1")]}
    ])
    |> with_header(session_id, cwd, %{"session_id" => parent_id, "seq" => parent_seq})
  end

  @doc """
  A summary sidecar as earlier versions wrote it: no journal size and
  modification time, no `context_tokens`, the search text inline, and a
  `"closed"` status.
  """
  def sidecar(session_id, title, last_seq) do
    summary = %{
      "session_id" => session_id,
      "title" => title,
      "cwd" => nil,
      "created_at" => @created_at,
      "updated_at" => @created_at,
      "status" => "closed",
      "model" => @model,
      "tags" => [],
      "message_count" => 2,
      "preview" => "before closing",
      "last_indexed_seq" => last_seq,
      "parent_session_id" => nil,
      "search_text" => "#{title}\nbefore closing"
    }

    :erlang.term_to_binary(
      %{
        "schema_version" => 1,
        "session_id" => session_id,
        "last_indexed_seq" => last_seq,
        "summary" => summary
      },
      [:compressed]
    )
  end

  @doc """
  The contents of a fallback `writer.lock` written before locks recorded the
  owner's process identity.
  """
  def lock_owner(pid, started_at) do
    JSON.encode!(%{"pid" => pid, "node" => "nonode@nohost", "started_at" => started_at})
  end

  @doc "The usage `pre_tree/2` stores on its last answer."
  def usage do
    %{
      "input_tokens" => 120,
      "output_tokens" => 30,
      "cache_read_tokens" => 64,
      "total_tokens" => 214,
      "cost" => 0.0021,
      "cost_breakdown" => %{"input" => 0.0012, "output" => 0.0009},
      "currency" => "USD",
      "model" => @model,
      "provider" => "test",
      # Before adapters returned canonical usage, the provider's own report
      # was kept here with its own key names.
      "raw" => %{"prompt_tokens" => 184, "completion_tokens" => 30}
    }
  end

  defp with_header(commits, session_id, cwd, parent) do
    header =
      Log.header(session_id: session_id, created_at: @created_at, cwd: cwd, parent: parent)

    [header | commits]
  end

  defp commits(session_id, entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {{turn_id, events}, seq} ->
      Log.commit(
        session_id: session_id,
        seq: seq,
        commit_id: "#{session_id}-commit-#{seq}",
        written_at: @created_at,
        turn_id: turn_id,
        events: events
      )
    end)
  end

  defp event(type, data), do: Log.event(type, data)

  defp created(cwd, data) do
    event("session.created", Map.merge(%{"cwd" => cwd, "title" => nil, "tags" => []}, data))
  end

  defp turn_started(turn_id, input) do
    event("turn.started", %{
      "turn_id" => turn_id,
      "operation" => "run",
      "input" => input,
      "started_at" => @created_at
    })
  end

  defp settled(turn_id) do
    event("turn.completed", %{"turn_id" => turn_id, "settled_at" => @created_at})
  end

  defp appended(message), do: event("message.appended", %{"message" => message})

  defp compacted(shadowed, first_retained) do
    event("context.compacted", %{
      "compaction_id" => "compaction-1",
      "trigger" => "manual",
      "summary_message" => user("summary-1", "Summary: the user listed the files."),
      "shadowed_message_ids" => shadowed,
      "first_retained_message_id" => first_retained,
      "previous_compaction_id" => nil,
      "tokens_before" => 400,
      "estimated_tokens_after" => 80,
      "summary_usage" => nil,
      "summary_model" => @model,
      "created_at" => @created_at,
      "details" => %{"pass" => 1}
    })
  end

  # Messages as the first durable codec encoded them: no "parts".
  defp user(id, content), do: message(id, "user", content, [])
  defp assistant(id, content, opts \\ []), do: message(id, "assistant", content, opts)

  defp tool(id, call_id, name, content) do
    message(id, "tool", content, tool_call_id: call_id, tool_name: name)
  end

  defp message(id, role, content, opts) do
    %{
      "id" => id,
      "role" => role,
      "content" => content,
      "thinking" => nil,
      "tool_calls" => Keyword.get(opts, :tool_calls, []),
      "tool_call_id" => Keyword.get(opts, :tool_call_id),
      "tool_name" => Keyword.get(opts, :tool_name),
      "timestamp" => @created_at,
      "token_usage" => Keyword.get(opts, :usage),
      "model" => if(role == "assistant", do: @model),
      "provider_state" => nil
    }
  end
end
