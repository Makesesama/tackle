defmodule Tackle.CLI.TUI.Resume do
  @moduledoc """
  The saved-session picker: `/resume`.

  A fullscreen, search-first picker over the project's durable sessions,
  modeled on Codex's `/resume` screen: a bold header, a live fuzzy query, a
  comfortable two-line list (title, then age and working directory) with the
  selected row highlighted, an expandable transcript preview for the selected
  session, and a footer with scroll progress and key hints.

  The list pages through the catalog: opening loads the first page, and moving
  near the end of the loaded rows loads the next one in the background. The
  query filters the loaded rows client-side and also matches session ids, so a
  remembered id finds its session.

  Selecting a row resumes that session through the frontend's resume hook,
  which stops the current scope only after the replacement is running. A
  session whose provider prompt cache has likely expired asks first, showing
  its estimated context size (`Tackle.CLI.TUI.ResumeConfirm`). The picker is
  idle-only.

  Tab switches to the project's archived sessions and back. Ctrl+A archives
  the selected session, or restores it in the archived view; selecting an
  archived session restores it and resumes it.

  Not ported from Codex: cross-project filtering (the resume hook is bound to
  the current project), fork actions, sort keys, and density toggles.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{MessageView, Picker, RecentSessions, ResumeConfirm, State, Util}
  alias Tackle.CLI.Widgets.ResumeScreen

  @load_near_end 3
  @small_result 10
  @preview_turns 6

  @typep preview :: ResumeScreen.preview()

  @typedoc "The overlay value while the picker is open."
  @type t :: %{
          view: :active | :archived,
          picker: Picker.t(),
          sessions: [map()],
          cursor: term() | nil,
          loading?: boolean(),
          load_ref: reference() | nil,
          load_kind: :first | :more,
          previews: %{optional(String.t()) => :loading | {:ok, preview()} | {:error, term()}},
          preview_ref: reference() | nil,
          expanded: String.t() | nil,
          scroll_top: non_neg_integer(),
          error: String.t() | nil
        }

  @doc """
  Opens the fullscreen picker when the shell is idle.

  The list is seeded from the dashboard's recent sessions so the screen is
  never empty, then the first catalog page loads in the background to refresh
  it and provide the pagination cursor.
  """
  @spec open(State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def open(%State{active_turn: turn} = state) when not is_nil(turn) do
    {:noreply, %{state | notice: "Resume is available when idle"}}
  end

  def open(%State{pending_operation: operation} = state) when not is_nil(operation) do
    {:noreply, %{state | notice: "Wait for the current operation to finish"}}
  end

  def open(%State{resume_session: nil} = state) do
    {:noreply, %{state | notice: "Session resume is unavailable in this frontend"}}
  end

  def open(%State{list_recent_sessions: nil} = state) do
    {:noreply, %{state | notice: "Session listing is unavailable in this frontend"}}
  end

  def open(%State{} = state) do
    resume = %{
      view: :active,
      picker: Picker.new(items(state.recent_sessions)),
      sessions: state.recent_sessions,
      cursor: nil,
      loading?: true,
      load_ref: nil,
      load_kind: :first,
      previews: %{},
      preview_ref: nil,
      expanded: nil,
      scroll_top: 0,
      error: nil
    }

    request_page(%{state | overlay: {:resume, resume}}, :first)
  end

  @doc "Handles one resolved resume-picker intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc "Applies a bracketed paste to the picker query."
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{overlay: {:resume, resume}} = state, content) do
    query = resume.picker.query <> String.replace(content, ~r/\s+/u, " ")
    %{state | overlay: {:resume, %{resume | picker: Picker.new(resume.picker.items, query)}}}
  end

  @doc """
  Installs a loaded catalog page into the open picker.

  A first page replaces the seeded list; a later page appends after dropping
  sessions that are already listed, so a session updated between page loads
  cannot appear twice.
  """
  @spec apply_page_result(State.t(), reference(), :first | :more, term()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply_page_result(
        %State{overlay: {:resume, %{load_ref: ref} = resume}} = state,
        ref,
        kind,
        result
      ) do
    resume = %{resume | loading?: false, load_ref: nil, load_kind: kind}

    case result do
      {:ok, %{sessions: sessions, next_cursor: cursor}} ->
        sessions = Enum.reject(sessions, &(Map.get(&1, :session_id) == state.session_id))

        sessions =
          if kind == :first,
            do: sessions,
            else: Enum.uniq_by(resume.sessions ++ sessions, &Map.get(&1, :session_id))

        resume = %{resume | sessions: sessions, cursor: cursor, error: nil}
        resume = %{resume | picker: rebuilt_picker(resume)}
        state = %{state | overlay: {:resume, resume}} |> sync_scroll()

        case load_more_commands(state) do
          [] -> {:noreply, state}
          commands -> {:noreply, state, commands: commands}
        end

      {:error, reason} ->
        resume = %{resume | error: Util.format_reason(reason)}
        {:noreply, %{state | overlay: {:resume, resume}}}

      other ->
        resume = %{resume | error: Util.format_reason({:invalid_session_page, other})}
        {:noreply, %{state | overlay: {:resume, resume}}}
    end
  end

  def apply_page_result(%State{} = state, _ref, _kind, _result),
    do: {:noreply, state, render?: false}

  @doc "Installs a loaded transcript preview into the open picker."
  @spec apply_preview_result(State.t(), reference(), String.t(), term()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply_preview_result(
        %State{overlay: {:resume, %{preview_ref: ref} = resume}} = state,
        ref,
        session_id,
        result
      ) do
    previews = Map.put(resume.previews, session_id, normalize_preview(result))
    resume = %{resume | previews: previews, preview_ref: nil}
    state = %{state | overlay: {:resume, resume}} |> sync_scroll()
    {:noreply, state}
  end

  def apply_preview_result(%State{} = state, _ref, _session_id, _result),
    do: {:noreply, state, render?: false}

  @doc """
  Returns the picker rows for `sessions`.

  The row prints the title or first message, while the query also matches the
  working directory and the session id, so a remembered id finds its session.
  """
  @spec items([map()]) :: [Picker.item()]
  def items(sessions) when is_list(sessions) do
    Enum.map(sessions, fn session ->
      %{
        id: Map.get(session, :session_id),
        primary: label(session),
        secondary: secondary(session),
        marker: " ",
        search: search_text(session),
        session: session
      }
    end)
  end

  @doc "Builds the fullscreen screen widget for the open picker."
  @spec popup(State.t()) :: ResumeScreen.t()
  def popup(%State{overlay: {:resume, resume}}) do
    rows = rows(resume)

    %ResumeScreen{
      rows: rows,
      selected: Util.clamp(resume.picker.selected, 0, max(length(rows) - 1, 0)),
      scroll_top: resume.scroll_top,
      query: resume.picker.query,
      count: length(rows),
      archived?: resume.view == :archived,
      loading?: resume.loading?,
      error: resume.error
    }
  end

  # -- rows ------------------------------------------------------------------

  defp rows(%{picker: picker, expanded: expanded, previews: previews}) do
    picker
    |> Picker.filtered()
    |> Enum.map(fn item ->
      preview = if item.id == expanded, do: Map.get(previews, item.id), else: nil

      %{
        id: item.id,
        title: item.primary,
        meta: item.secondary,
        preview: preview,
        expanded?: item.id == expanded
      }
    end)
  end

  defp label(session) do
    text = Map.get(session, :title) || Map.get(session, :preview) || Map.get(session, :session_id)

    text
    |> MessageView.sanitize()
    |> String.split("\n", parts: 2)
    |> hd()
    |> Util.truncate(60)
  end

  defp secondary(session) do
    updated_at = Map.get(session, :updated_at) || Map.get(session, :created_at)

    [relative_time(updated_at), directory(Map.get(session, :cwd))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ·  ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp directory(nil), do: nil

  defp directory(cwd), do: cwd |> String.replace_trailing("/", "") |> Util.truncate(36)

  defp search_text(session) do
    [:title, :preview, :cwd, :session_id]
    |> Enum.map(&Map.get(session, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp relative_time(nil), do: nil

  defp relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> relative(DateTime.diff(DateTime.utc_now(), at), at)
      {:error, _reason} -> nil
    end
  end

  defp relative(seconds, _at) when seconds < 60, do: "just now"
  defp relative(seconds, _at) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp relative(seconds, _at) when seconds < 86_400, do: "#{div(seconds, 3600)}h ago"
  defp relative(seconds, _at) when seconds < 604_800, do: "#{div(seconds, 86_400)}d ago"
  defp relative(_seconds, at), do: Calendar.strftime(at, "%b %d")

  # -- dispatch ----------------------------------------------------------------

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}

  # Esc clears an active query first and closes the picker on the second press.
  defp dispatch(:cancel, %State{overlay: {:resume, resume}} = state) do
    if resume.picker.query == "" do
      {:noreply, %{state | overlay: nil}}
    else
      picker = Picker.new(resume.picker.items, "")
      {:noreply, %{state | overlay: {:resume, %{resume | picker: picker}}}}
    end
  end

  defp dispatch(:previous, state), do: move(state, -1)
  defp dispatch(:next, state), do: move(state, 1)

  defp dispatch(:page_up, state), do: move(state, -page_size(state))
  defp dispatch(:page_down, state), do: move(state, page_size(state))

  defp dispatch(:accept, %State{overlay: {:resume, resume}} = state) do
    case Picker.selected(resume.picker) do
      nil -> {:noreply, state, render?: false}
      %{session: session} -> ResumeConfirm.request(state, session)
    end
  end

  defp dispatch(:toggle_view, %State{list_archived_sessions: nil} = state),
    do: {:noreply, %{state | notice: "Archived sessions are unavailable in this frontend"}}

  defp dispatch(:toggle_view, %State{overlay: {:resume, resume}} = state) do
    {view, sessions} =
      case resume.view do
        :active -> {:archived, []}
        :archived -> {:active, state.recent_sessions}
      end

    resume = %{
      resume
      | view: view,
        sessions: sessions,
        picker: Picker.new(items(sessions), resume.picker.query),
        cursor: nil,
        expanded: nil,
        scroll_top: 0,
        error: nil
    }

    request_page(%{state | overlay: {:resume, resume}}, :first)
  end

  defp dispatch(:archive, %State{overlay: {:resume, resume}} = state) do
    case Picker.selected(resume.picker) do
      nil -> {:noreply, state, render?: false}
      %{id: session_id} -> toggle_archived(state, resume, session_id)
    end
  end

  defp dispatch(:expand, %State{overlay: {:resume, resume}} = state) do
    case Picker.selected(resume.picker) do
      nil ->
        {:noreply, state, render?: false}

      %{id: session_id} when resume.expanded == session_id ->
        collapse(state, resume)

      %{id: session_id} ->
        expand(state, resume, session_id)
    end
  end

  defp dispatch(:collapse, %State{overlay: {:resume, resume}} = state),
    do: collapse(state, resume)

  defp dispatch(:backspace, %State{overlay: {:resume, resume}} = state) do
    picker = Picker.backspace(resume.picker)
    {:noreply, %{state | overlay: {:resume, %{resume | picker: picker}}}}
  end

  defp dispatch({:insert, text}, %State{overlay: {:resume, resume}} = state) do
    picker = Picker.insert(resume.picker, text)
    {:noreply, %{state | overlay: {:resume, %{resume | picker: picker}}}}
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  # Archiving moves the session out of the listed view; the dashboard's recent
  # sessions are reloaded because the session may be one of them.
  defp toggle_archived(state, resume, session_id) do
    {hook, done} =
      case resume.view do
        :active -> {state.archive_session, "Archived session"}
        :archived -> {state.unarchive_session, "Restored session"}
      end

    case run_hook(hook, session_id) do
      :ok ->
        sessions = Enum.reject(resume.sessions, &(Map.get(&1, :session_id) == session_id))
        resume = %{resume | sessions: sessions, expanded: nil, error: nil}
        resume = %{resume | picker: rebuilt_picker(resume)}
        state = %{state | overlay: {:resume, resume}, notice: done} |> sync_scroll()
        {state, commands} = RecentSessions.load(state)
        {:noreply, state, commands: commands ++ load_more_commands(state)}

      {:error, reason} ->
        resume = %{resume | error: archive_error(resume.view, reason)}
        {:noreply, %{state | overlay: {:resume, resume}}}
    end
  end

  defp run_hook(nil, _session_id), do: {:error, :unavailable}

  defp run_hook(hook, session_id) do
    case hook.(session_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp archive_error(view, reason) do
    verb = if view == :active, do: "archive", else: "restore"

    detail =
      case reason do
        :unavailable -> "unavailable in this frontend"
        :session_active -> "the session is open"
        {:session_in_use, _owner} -> "the session is open in another Tackle process"
        :session_in_use -> "the session is open in another Tackle process"
        {:session_exists, _id} -> "an active session with this id exists"
        {:session_not_found, _id} -> "the session no longer exists"
        other -> Util.format_reason(other)
      end

    "Could not #{verb}: #{detail}"
  end

  # Expanding or collapsing changes the selected row's height, so the window
  # must re-anchor; otherwise the next move starts from a stale scroll top.
  defp collapse(state, resume) do
    state = %{state | overlay: {:resume, %{resume | expanded: nil}}}
    {:noreply, sync_scroll(state)}
  end

  defp expand(state, resume, session_id) do
    resume = %{resume | expanded: session_id}

    cond do
      Map.has_key?(resume.previews, session_id) ->
        state = %{state | overlay: {:resume, resume}} |> sync_scroll()
        {:noreply, state}

      state.inspect_session == nil ->
        previews = Map.put(resume.previews, session_id, {:error, :no_inspector})
        state = %{state | overlay: {:resume, %{resume | previews: previews}}} |> sync_scroll()
        {:noreply, state}

      true ->
        request_preview(state, resume, session_id)
    end
  end

  defp request_preview(state, resume, session_id) do
    ref = make_ref()
    inspector = state.inspect_session

    command =
      Command.async(
        fn -> inspector.(session_id) end,
        &{:tui_resume_preview_result, ref, session_id, &1}
      )

    resume = %{
      resume
      | previews: Map.put(resume.previews, session_id, :loading),
        preview_ref: ref
    }

    state = %{state | overlay: {:resume, resume}} |> sync_scroll()
    {:noreply, state, commands: [command]}
  end

  # -- movement and paging -----------------------------------------------------

  defp move(%State{overlay: {:resume, resume}} = state, delta) do
    picker = Picker.move(resume.picker, delta)
    resume = %{resume | picker: picker}
    state = %{state | overlay: {:resume, resume}}
    state = sync_scroll(state)
    {:noreply, state, commands: load_more_commands(state)}
  end

  defp page_size(%State{overlay: {:resume, resume}, size: size}) do
    resume
    |> rows()
    |> ResumeScreen.window(
      resume.scroll_top,
      resume.picker.selected,
      ResumeScreen.list_height(size)
    )
    |> Map.get(:visible)
    |> length()
    |> max(1)
  end

  # Keeps the selection inside the window after every move, so the picker
  # scrolls only when the selection reaches an edge.
  defp sync_scroll(%State{overlay: {:resume, resume}, size: size} = state) do
    win =
      ResumeScreen.window(
        rows(resume),
        resume.scroll_top,
        resume.picker.selected,
        ResumeScreen.list_height(size)
      )

    %{state | overlay: {:resume, %{resume | scroll_top: win.scroll_top}}}
  end

  # Loads the next catalog page when the selection approaches the end of the
  # loaded rows, or when a query leaves fewer matches than a small result —
  # more pages may hold further matches.
  defp load_more_commands(%State{overlay: {:resume, resume}} = state) do
    count = resume.picker |> Picker.filtered() |> length()
    near_end? = resume.picker.selected >= count - @load_near_end

    if resume.cursor != nil and not resume.loading? and (near_end? or count < @small_result) do
      request_page(state, :more) |> commands()
    else
      []
    end
  end

  defp request_page(%State{overlay: {:resume, resume}} = state, kind) do
    ref = make_ref()

    loader =
      case resume.view do
        :active -> state.list_recent_sessions
        :archived -> state.list_archived_sessions
      end

    cursor = if kind == :first, do: nil, else: resume.cursor

    command =
      Command.async(
        fn -> loader.(cursor) end,
        &{:tui_resume_page_result, ref, kind, &1}
      )

    resume = %{resume | loading?: true, load_ref: ref, load_kind: kind}
    {:noreply, %{state | overlay: {:resume, resume}}, commands: [command]}
  end

  defp commands({:noreply, _state, commands: commands}), do: commands

  # Rebuilds the picker over the loaded sessions while keeping the query and
  # the clamped selection, so a page arriving mid-search never jumps the view.
  defp rebuilt_picker(resume) do
    items = items(resume.sessions)
    count = length(items)
    selected = Util.clamp(resume.picker.selected, 0, max(count - 1, 0))
    %Picker{items: items, query: resume.picker.query, selected: selected}
  end

  # -- previews ----------------------------------------------------------------

  defp normalize_preview({:ok, inspected}) do
    {:ok, preview_lines(Map.get(inspected, :messages))}
  end

  defp normalize_preview({:error, reason}), do: {:error, reason}
  defp normalize_preview(other), do: {:error, {:invalid_inspect_result, other}}

  defp preview_lines(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(Map.get(&1, "role") in ["user", "assistant"]))
    |> Enum.take(@preview_turns)
    |> Enum.map(fn message ->
      %{
        speaker: preview_speaker(Map.get(message, "role")),
        text: preview_text(Map.get(message, "content"))
      }
    end)
  end

  defp preview_lines(_other), do: []

  defp preview_speaker("user"), do: :user
  defp preview_speaker(_other), do: :assistant

  defp preview_text(content) when is_binary(content),
    do: content |> String.split("\n", parts: 2) |> hd()

  defp preview_text(_other), do: ""
end
