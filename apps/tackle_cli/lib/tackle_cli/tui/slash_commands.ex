defmodule Tackle.CLI.TUI.SlashCommands do
  @moduledoc """
  `/` commands: one registry shared by the composer popup and dispatch.

  Typing `/` at the start of the draft opens a filtered list of commands
  anchored above the composer, in the spirit of the Codex TUI's command
  popup. The same registry answers dispatch, so the commands the popup
  offers and the commands a submitted draft runs cannot drift apart —
  `Tackle.CLI.TUI.Composer.submit/1` routes every `/name` draft through
  `dispatch/2` instead of matching command names itself.

  The popup floats above the composer without taking over editing: typing
  keeps refining the query, `↑`/`↓` (or Ctrl+P/N) move the selection, Tab
  completes the selected name into the draft, Enter runs the selected
  command, and Esc dismisses the popup for the current name fragment. The
  popup is open only while the caret is inside the leading `/name` fragment;
  once a space follows the name, `@` mentions and ordinary text take over
  again.

  Filtering keeps the registry's presentation order — deliberately not
  alphabetical, like Codex's — with an exact name match before prefix
  matches. A draft naming an unknown command is not a command: it is
  submitted as an ordinary prompt, exactly as before.

  Like `Tackle.CLI.TUI.FileSearch`, this module never pattern-matches the
  shell state struct: `Tackle.CLI.TUI.State` embeds a `%__MODULE__{}` as its
  default, so the dependency must stay one-way.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.Widgets.Input

  alias Tackle.CLI.TUI.{
    Browser,
    Compaction,
    CompletionPopup,
    Help,
    History,
    Menu,
    Workflows,
    Resume,
    Session,
    Subagents,
    Theme,
    Tree,
    UsageChart,
    Util,
    Viewport
  }

  @typedoc "One registered command."
  @type command :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:action) => atom(),
          optional(:idle_only?) => boolean()
        }

  @typedoc "The name fragment Esc has dismissed."
  @type t :: %__MODULE__{dismissed: String.t() | nil}

  @typedoc "View state for the open popup."
  @type popup :: %{
          query: String.t(),
          matches: [command()],
          selected: non_neg_integer()
        }

  # Rows shown in the popup, like the file-mention popup.
  @max_rows 8

  # Presentation order, deliberately not alphabetical: more frequently used
  # commands come first, like Codex's command list. `idle_only?` commands are
  # hidden (and refuse to run) while a turn or operation is in flight.
  @commands [
    %{name: "model", description: "pick the model · F1", action: :model_picker},
    %{name: "thinking", description: "pick the reasoning level · F2", action: :thinking_picker},
    %{name: "settings", description: "open settings · F3", action: :settings_picker},
    %{name: "resume", description: "resume a saved session", action: :resume, idle_only?: true},
    %{
      name: "tree",
      description: "jump to an earlier branch · F5",
      action: :tree,
      idle_only?: true
    },
    %{name: "compact", description: "compact the context · Ctrl+K", action: :compact},
    %{name: "new", description: "start a new session", action: :new_session},
    %{name: "browse", description: "read the transcript · F4", action: :browse},
    %{name: "usage", description: "token usage chart · F6", action: :usage_chart},
    %{name: "tasks", description: "inspect subagent tasks · F7", action: :subagents},
    %{name: "workflows", description: "run, edit, or create saved workflows", action: :workflows},
    %{name: "help", description: "shortcut reference · ?", action: :help}
  ]

  defstruct dismissed: nil

  # -- registry -------------------------------------------------------------

  @doc "Returns the registered command named `name`, or `nil`."
  @spec find(String.t()) :: command() | nil
  def find(name) when is_binary(name),
    do: Enum.find(@commands, &(&1.name == name))

  @doc "Returns the commands that can run in `state`, in presentation order."
  @spec commands(map()) :: [command()]
  def commands(state),
    do: Enum.filter(@commands, &available?(&1, state))

  @doc "Whether `command` can run now; idle-only commands need an idle shell."
  @spec available?(command(), map()) :: boolean()
  def available?(command, state),
    do: not Map.get(command, :idle_only?, false) or idle?(state)

  defp idle?(state),
    do: state.active_turn == nil and state.pending_operation == nil

  @doc """
  Parses a draft as a slash command.

  Returns `{name, args}` when the trimmed draft starts with `/`, with `name`
  the first whitespace-delimited token after the slash and `args` the
  remaining text. Anything else is not a command.
  """
  @spec parse(String.t()) :: {String.t(), String.t()} | nil
  def parse(draft) when is_binary(draft) do
    case String.trim_leading(draft) do
      "/" <> rest -> split(rest)
      _other -> nil
    end
  end

  defp split(rest) do
    case :binary.split(rest, [" ", "\t", "\n", "\r"]) do
      [name] -> {name, ""}
      [name, args] -> {name, String.trim(args)}
    end
  end

  # -- dispatch -------------------------------------------------------------

  @doc """
  Runs the slash command a submitted draft names.

  Returns the command's reply when the draft names an available command, a
  notice when it names a command that cannot run now, and `:prompt` when the
  draft is not a command at all — the caller submits that as an ordinary
  prompt. A command that acted clears the draft; one that refused keeps it,
  so a failure never loses what the user typed.
  """
  @spec dispatch(map(), String.t()) ::
          :prompt | {:noreply, map()} | {:noreply, map(), keyword()}
  def dispatch(state, draft) do
    case parse(draft) do
      {name, _args} ->
        case find(name) do
          nil -> :prompt
          command -> execute(command, state)
        end

      nil ->
        :prompt
    end
  end

  defp execute(command, state) do
    if available?(command, state) do
      run(command, state)
    else
      {:noreply, %{state | notice: "/#{command.name} is available when idle · draft kept"}}
    end
  end

  defp run(command, state) do
    {updated, opts} =
      case action(command.action, state) do
        {:noreply, updated} -> {updated, []}
        {:noreply, updated, opts} -> {updated, opts}
      end

    updated =
      if acted?(state, updated),
        do: updated |> close_popup() |> clear_draft(),
        else: updated

    if opts == [], do: {:noreply, updated}, else: {:noreply, updated, opts}
  end

  # One clause per action: an addition to the registry fails loudly here until
  # it is given behaviour, instead of silently doing nothing.
  defp action(:model_picker, state), do: Menu.open(:model, state)
  defp action(:thinking_picker, state), do: Menu.open(:thinking, state)
  defp action(:settings_picker, state), do: Menu.open(:settings, state)
  defp action(:resume, state), do: Resume.open(state)
  defp action(:tree, state), do: Tree.open(state)
  defp action(:compact, state), do: Compaction.request(state)
  defp action(:new_session, state), do: Session.request_new(state)
  defp action(:browse, state), do: Browser.toggle_focus(state)
  defp action(:usage_chart, state), do: UsageChart.open(state)
  defp action(:subagents, state), do: Subagents.focus(state)
  defp action(:workflows, state), do: Workflows.open(state)
  defp action(:help, state), do: Help.open(state)

  # A command acted when it opened an overlay, moved focus, or started an
  # operation. A refusal leaves all three untouched, so the draft survives it.
  defp acted?(before, updated) do
    updated.focus != before.focus or
      updated.pending_operation != before.pending_operation or
      (not is_nil(updated.overlay) and updated.overlay != before.overlay)
  end

  defp close_popup(%{overlay: {:slash_commands, _popup}} = state), do: %{state | overlay: nil}
  defp close_popup(state), do: state

  defp clear_draft(state) do
    :ok = Input.set_value(state.input, "")
    state |> Viewport.update_draft() |> Viewport.relayout()
  end

  # -- popup synchronization ------------------------------------------------

  @doc """
  Brings the popup in line with the draft after any edit.

  Opens or updates the `{:slash_commands, popup}` overlay while the caret is
  inside the leading `/name` fragment and the composer has the keyboard;
  closes it otherwise. Another overlay always wins: while a menu owns the
  screen the popup stays closed, and this function leaves that overlay
  untouched. The command list is static, so unlike the file-mention popup
  there is nothing to build and no command is returned.
  """
  @spec sync(map()) :: {map(), []}
  def sync(state) do
    cond do
      not manages?(state.overlay) -> {state, []}
      state.focus != :composer -> {close(state), []}
      true -> sync_fragment(state)
    end
  end

  defp manages?(nil), do: true
  defp manages?({:slash_commands, _popup}), do: true
  defp manages?(_other_overlay), do: false

  defp close(%{overlay: {:slash_commands, _popup}} = state), do: %{state | overlay: nil}
  defp close(state), do: state

  defp sync_fragment(state) do
    case fragment(Input.get_value(state.input), Input.cursor(state.input)) do
      nil ->
        {close(state), []}

      query ->
        if state.slash_commands.dismissed == query,
          do: {close(state), []},
          else: {open(state, query), []}
    end
  end

  @doc """
  Returns the leading `/name` fragment under the caret.

  The fragment is the whitespace-delimited run after a `/` that starts the
  draft, and it exists only while the caret is inside it — once a space
  follows the name the popup closes and `@` mentions work again. Returns
  `nil` when the draft does not start with `/` or the caret has moved past
  the name.
  """
  @spec fragment(String.t(), non_neg_integer()) :: String.t() | nil
  def fragment(draft, cursor) when is_binary(draft) and is_integer(cursor) and cursor >= 0 do
    case draft do
      "/" <> rest ->
        cursor = Util.floor_boundary(draft, min(cursor, byte_size(draft)))
        name_end = name_end(rest, 0)
        if cursor <= name_end + 1, do: binary_part(rest, 0, name_end)

      _other ->
        nil
    end
  end

  defp name_end(<<byte, _rest::binary>>, offset) when byte in [0x20, 0x09, 0x0A, 0x0D],
    do: offset

  defp name_end(<<_byte, rest::binary>>, offset), do: name_end(rest, offset + 1)
  defp name_end(<<>>, offset), do: offset

  defp open(state, query) do
    {previous_query, previous_selected} =
      case state.overlay do
        {:slash_commands, popup} -> {popup.query, popup.selected}
        _other -> {nil, 0}
      end

    matches = filter(commands(state), query)

    selected =
      if previous_query == query,
        do: min(previous_selected, max(length(matches) - 1, 0)),
        else: 0

    %{state | overlay: {:slash_commands, %{query: query, matches: matches, selected: selected}}}
  end

  @doc """
  Returns the commands whose names match `query`, best first.

  An exact name match comes first, then prefix matches; both keep the
  registry's presentation order. An empty query matches every command.
  """
  @spec filter([command()], String.t()) :: [command()]
  def filter(commands, query) when query in ["", nil], do: commands

  def filter(commands, query) do
    needle = String.downcase(query)

    exact = for command <- commands, command.name == needle, do: command

    prefix =
      for command <- commands,
          command.name != needle and String.starts_with?(command.name, needle),
          do: command

    exact ++ prefix
  end

  # -- popup keys -----------------------------------------------------------

  @doc """
  Handles one resolved command-popup intent.

  `↑`/`↓` wrap around the matches. `:complete` replaces the fragment with
  the selected `/name` followed by a separator space, ready for inline
  arguments. `:accept` runs the selected command like a submitted draft; with
  nothing selected it falls through to a normal submission, which sends an
  unknown `/word` as an ordinary prompt.
  """
  @spec handle(atom(), map()) ::
          {:noreply, map()} | {:noreply, map(), keyword()}
  def handle(:previous, state), do: {:noreply, move(state, -1)}
  def handle(:next, state), do: {:noreply, move(state, 1)}

  def handle(:close, %{overlay: {:slash_commands, popup}} = state) do
    {:noreply,
     %{state | overlay: nil, slash_commands: %{state.slash_commands | dismissed: popup.query}}}
  end

  def handle(:complete, %{overlay: {:slash_commands, popup}} = state) do
    case Enum.at(popup.matches, popup.selected) do
      nil -> {:noreply, state, render?: false}
      command -> complete(state, popup, command)
    end
  end

  def handle(:accept, %{overlay: {:slash_commands, popup}} = state) do
    case Enum.at(popup.matches, popup.selected) do
      nil -> Tackle.CLI.TUI.Composer.submit(state)
      command -> execute(command, state)
    end
  end

  def handle(:ignore, state), do: {:noreply, state, render?: false}

  defp move(%{overlay: {:slash_commands, popup}} = state, delta) do
    count = length(popup.matches)

    selected =
      if count == 0, do: 0, else: Integer.mod(popup.selected + delta, count)

    %{state | overlay: {:slash_commands, %{popup | selected: selected}}}
  end

  defp complete(state, popup, command) do
    # The fragment always starts the draft, so the replaced range is "/" plus
    # the query; the trailing space moves the caret past the name, which
    # closes the popup on the next sync.
    :ok =
      Input.replace_range(state.input, 0, 1 + byte_size(popup.query), "/" <> command.name <> " ")

    state = %{
      state
      | overlay: nil,
        slash_commands: %{state.slash_commands | dismissed: nil},
        history: History.leave_browsing(state.history)
    }

    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
  end

  # -- rendering ------------------------------------------------------------

  @doc """
  Builds the popup anchored directly above the composer's rectangle.

  Returns `{widget, rect}` pairs: the shared chrome (a clear plus the panel
  block) and the command list or hint inside it. The popup is skipped when
  the terminal is too short to fit it above the input bar.
  """
  @spec widgets(map(), Rect.t()) :: [{struct(), Rect.t()}]
  def widgets(%{overlay: {:slash_commands, popup}}, composer) do
    rows = popup |> match_rows() |> max(1)

    case CompletionPopup.anchor(title(popup), rows, composer) do
      :skip -> []
      {chrome, inner} -> chrome ++ [{content(popup, inner.width), inner}]
    end
  end

  defp match_rows(popup), do: min(length(popup.matches), @max_rows)

  defp title(popup) do
    count = length(popup.matches)

    filter =
      if popup.query == "", do: "type to filter", else: "“#{Util.truncate(popup.query, 24)}”"

    " Commands · #{count} · #{filter} "
  end

  defp content(%{matches: []}, _width) do
    %Paragraph{text: " No matching command", style: Theme.style(:muted)}
  end

  defp content(%{matches: matches, selected: selected}, width) do
    name_width = matches |> Enum.map(&byte_size(&1.name)) |> Enum.max()

    items =
      for command <- matches do
        name = String.pad_trailing("/" <> command.name, name_width + 1)
        Util.truncate("#{name}  #{command.description}", max(width - 2, 1))
      end

    %SelectionList{
      items: items,
      selected: min(selected, max(length(matches) - 1, 0)),
      highlight_symbol: "› ",
      highlight_style: Theme.merge(Theme.style(:selection_surface), Theme.style(:accent)),
      style: Theme.style(:text),
      scroll_padding: 0
    }
  end
end
