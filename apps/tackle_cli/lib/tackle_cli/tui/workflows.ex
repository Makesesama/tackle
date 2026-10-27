defmodule Tackle.CLI.TUI.Workflows do
  @moduledoc """
  Search-first saved-workflow picker (`/workflows`).

  Running submits an ordinary agent prompt. Editing is available even during
  a turn; files are fetched again before editing and
  written through the session executor. New files are created exclusively only
  after a successful editor exit with a changed template.
  """

  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Widgets.{Paragraph, Popup}
  alias Tackle.CLI.TUI.{Composer, ExternalEditor, Picker, State, Theme, Util}
  alias Tackle.Workflows, as: Saved

  @doc "Re-discovers workflows and opens the picker, including while busy."
  @spec open(State.t()) :: {:noreply, State.t()}
  def open(state), do: {:noreply, discover(state, "")}

  @doc "Handles one resolved workflow-picker intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:close, state), do: {:noreply, %{state | overlay: nil}}
  def handle(:ignore, state), do: {:noreply, state, render?: false}

  def handle(direction, %{overlay: {:workflows, menu}} = state)
      when direction in [:previous, :next] do
    delta = if direction == :previous, do: -1, else: 1
    {:noreply, put_picker(state, Picker.move(menu.picker, delta))}
  end

  def handle(:backspace, %{overlay: {:workflows, menu}} = state),
    do: {:noreply, update_query(state, Picker.backspace(menu.picker))}

  def handle({:insert, text}, %{overlay: {:workflows, menu}} = state),
    do: {:noreply, update_query(state, Picker.insert(menu.picker, text))}

  def handle(intent, %{overlay: {:workflows, menu}} = state)
      when intent in [:accept, :external_editor] do
    case {intent, Picker.selected(menu.picker)} do
      {_, nil} -> {:noreply, state, render?: false}
      {:accept, %{id: {:new, name}}} -> create(state, name)
      {:external_editor, %{id: {:new, _}}} -> {:noreply, state, render?: false}
      {:external_editor, %{id: name}} -> edit(state, name)
      {:accept, %{id: name}} -> run(state, name)
    end
  end

  @doc "Applies a bracketed paste as single-line query text."
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%{overlay: {:workflows, menu}} = state, content),
    do: update_query(state, Picker.insert(menu.picker, String.replace(content, ~r/\s+/u, " ")))

  defp run(state, name) do
    if state.active_turn != nil or state.pending_operation != nil do
      {:noreply, %{state | notice: "Saved workflows can run only when idle"}}
    else
      Composer.submit_prompt(%{state | overlay: nil}, ~s(Run the saved workflow "#{name}".))
    end
  end

  defp edit(state, name) do
    case Saved.fetch(name, options(state)) do
      {:ok, workflow, script} ->
        ExternalEditor.run(
          state,
          script,
          state.workflow_editor,
          fn state, edited ->
            result =
              if edited == script,
                do: :unchanged,
                else: Saved.save(workflow.path, edited, options(state))

            notice =
              case result do
                :ok -> "Saved #{display_path(state, workflow.path)}"
                :unchanged -> "Workflow unchanged"
                {:error, reason} -> "Could not save workflow: #{describe(reason)}"
              end

            refresh(state, notice)
          end,
          "workflow"
        )

      {:error, reason} ->
        {:noreply, refresh(state, "Could not read workflow: #{describe(reason)}")}
    end
  end

  defp create(state, name) do
    template = Saved.template(name)

    ExternalEditor.run(
      state,
      template,
      state.workflow_editor,
      fn state, edited ->
        notice =
          if edited == template do
            "Workflow not created (template unchanged)"
          else
            case Saved.create(name, edited, options(state)) do
              {:ok, path} -> "Created #{display_path(state, path)}"
              {:error, reason} -> "Could not create workflow: #{describe(reason)}"
            end
          end

        refresh(state, notice)
      end,
      "workflow"
    )
  end

  defp refresh(%{overlay: {:workflows, menu}} = state, notice),
    do: %{discover(state, menu.picker.query) | notice: notice}

  defp discover(state, query) do
    %{workflows: workflows, warnings: warnings} = Saved.discover(options(state))
    picker = build_picker(workflows, query)
    state = %{state | overlay: {:workflows, %{workflows: workflows, picker: picker}}}

    case warnings do
      [] ->
        state

      [warning | rest] ->
        %{
          state
          | notice:
              "Workflows: #{warning.path}: #{warning.message}" <>
                if(rest == [], do: "", else: " · #{length(rest)} more warnings")
        }
    end
  end

  defp update_query(%{overlay: {:workflows, menu}} = state, picker),
    do: put_picker(state, build_picker(menu.workflows, picker.query))

  defp put_picker(%{overlay: {:workflows, menu}} = state, picker),
    do: %{state | overlay: {:workflows, %{menu | picker: picker}}}

  defp build_picker(workflows, query) do
    items =
      Enum.map(workflows, fn workflow ->
        %{
          id: workflow.name,
          primary: workflow.name,
          secondary:
            [workflow.description, "[#{workflow.source}]"]
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(" "),
          search: "#{workflow.name} #{workflow.description}"
        }
      end)

    trailing_items =
      if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, query) and
           not Enum.any?(workflows, &(&1.name == query)) do
        [
          %{
            id: {:new, query},
            primary: ~s(+ new workflow "#{query}"),
            secondary: nil,
            search: query
          }
        ]
      else
        []
      end

    %{Picker.new(items, query) | trailing_items: trailing_items}
  end

  # Run uses the process cwd for its session loader. Capture the same default
  # when mounting the shell; explicit cwd/env keep tests independent of globals.
  defp options(state),
    do: [cwd: cwd(state), executor: state.executor, env: state.env || System.get_env()]

  defp cwd(state), do: state.cwd || File.cwd!()

  defp describe(:eexist), do: "a workflow with that name already exists"
  defp describe(:invalid_name), do: "names use lowercase letters, numbers, and single hyphens"
  defp describe(:invalid_utf8), do: "the file is not UTF-8 text"

  defp describe(:no_project_dir),
    do: "there is no project directory here (it would be $TACKLE_HOME/workflows)"

  defp describe({:unknown_workflow, name, _names}),
    do: "#{inspect(name)} no longer exists"

  defp describe(reason), do: Tackle.Executor.format_reason(reason)
  defp display_path(state, path), do: Path.relative_to(path, cwd(state))

  @doc "Renders the picker with run/edit/create guidance and an empty-state hint."
  @spec popup(State.t()) :: Popup.t()
  def popup(%{overlay: {:workflows, menu}}) do
    items = Picker.filtered(menu.picker)

    content =
      case items do
        [] ->
          %Paragraph{
            text:
              " No saved workflows match.\n\n Workflows live in .tackle/workflows or $TACKLE_HOME/workflows.\n Type a lowercase-hyphenated name to create one,\n or ask the agent to write one.",
            style: Theme.style(:muted)
          }

        items ->
          %SelectionList{
            items: Enum.map(items, &Picker.row/1),
            selected: Util.clamp(menu.picker.selected, 0, max(length(items) - 1, 0)),
            highlight_symbol: "› ",
            highlight_style: Theme.merge(Theme.style(:selection_surface), Theme.style(:accent)),
            style: Theme.style(:text),
            scroll_padding: 2
          }
      end

    query =
      if menu.picker.query == "",
        do: "type a name to create",
        else: "“#{Util.truncate(menu.picker.query, 24)}”"

    %Popup{
      content: content,
      block: Theme.panel_block(" Workflows · Enter run · Ctrl+G edit · #{query} ", :accent),
      percent_width: 85,
      percent_height: 55
    }
  end
end
