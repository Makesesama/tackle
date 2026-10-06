defmodule Tackle.CLI.TUI.ToolGroupsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{MessageView, ToolGroups, ToolView}
  alias Tackle.Lib.{Message, State}

  describe "classify/1" do
    test "read tool calls are exploring by definition" do
      assert classify_read("lib/tackle_cli/tui/tool_view.ex") == [{:read, "tool_view.ex"}]
      assert classify_read("packages/app/src") == [{:read, "app"}]
    end

    test "classifies common read-only bash commands" do
      assert classify("cat lib/parser.ex") == [{:read, "parser.ex"}]
      assert classify("sed -n 12,40p mix.exs") == [{:read, "mix.exs"}]
      assert classify("sed -n -e 45p lib/a.ex") == [{:read, "a.ex"}]
      assert classify("head -n 20 CHANGELOG.md") == [{:read, "CHANGELOG.md"}]
      assert classify("bat --style=plain README.md") == [{:read, "README.md"}]
      assert classify("less TODO.md") == [{:read, "TODO.md"}]
    end

    test "classifies listings and searches" do
      assert classify("ls -la packages") == [{:list, "packages"}]
      assert classify("tree -L 2") == [{:list, nil}]
      assert classify("find lib -name '*.ex'") == [{:search, "*.ex", "lib"}]
      assert classify("find . -type f") == [{:list, "."}]
      assert classify("rg --files test") == [{:list, "test"}]
      assert classify("rg \"defmodule\" lib") == [{:search, "defmodule", "lib"}]
      assert classify("grep -rn 'TODO' .") == [{:search, "TODO", "."}]
      assert classify("git grep 'parse_command'") == [{:search, "parse_command", nil}]
      assert classify("git ls-files packages") == [{:list, "packages"}]
      assert classify("fd 'activity' src") == [{:search, "activity", "src"}]
      assert classify("fd lib/") == [{:list, "lib"}]
    end

    test "compound commands classify only when every segment does" do
      assert classify("cd lib && cat parser.ex") == [{:read, "parser.ex"}]

      assert classify("ls packages && rg defmodule lib") == [
               {:list, "packages"},
               {:search, "defmodule", "lib"}
             ]

      assert classify("cat a.ex | wc -l") == [{:read, "a.ex"}]
      assert classify("grep foo lib || true") == [{:search, "foo", "lib"}]
      assert classify("ls; echo done") == [{:list, nil}]
      assert classify("ls;echo done") == [{:list, nil}]
      assert classify("cat a.ex\ncat b.ex") == [{:read, "a.ex"}, {:read, "b.ex"}]
    end

    test "mutating and unrecognized commands are never exploring" do
      assert classify("rm -rf build") == :unknown
      assert classify("git status") == :unknown
      assert classify("mix test") == :unknown
      assert classify("cat a.ex && rm a.ex") == :unknown
      assert classify("sed -i 's/a/b/' mix.exs") == :unknown
      assert classify("cat") == :unknown
      assert classify("") == :unknown
    end

    test "unwraps shell invocations and quotes" do
      assert classify(~s{bash -lc "cat 'lib/a b.ex'"}) == [{:read, "a b.ex"}]
      assert classify(~s{sh -c 'rg "def module" lib'}) == [{:search, "def module", "lib"}]
    end

    test "non-tool entries and unknown tools never classify" do
      refute ToolGroups.exploring?(%{kind: :assistant, content: "hi"})
      refute ToolGroups.exploring?(bash_entry("mix test"))
      assert ToolGroups.exploring?(bash_entry("cat mix.exs"))
    end
  end

  describe "group/1" do
    test "consecutive exploring calls collapse into one group entry" do
      entries =
        settled(
          assistant_calls(
            read: {"a", "lib/a.ex"},
            bash: {"b", "ls packages"},
            read: {"c", "lib/b.ex"}
          ) ++
            [
              Message.tool_result("a", "read", "a output"),
              Message.tool_result("b", "bash", "b output"),
              Message.tool_result("c", "read", "c output")
            ]
        )

      assert [%{kind: :tool, tool_name: "explore", id: "group:tool:a"}] = entries
      group = hd(entries)
      assert Enum.map(group.tool_group, & &1.id) == ["tool:a", "tool:b", "tool:c"]
      assert group.tool_status == :completed
      assert group.tool_elapsed_ms == nil
    end

    test "a lone exploring call keeps its normal card" do
      [entry] =
        settled(
          assistant_calls(read: {"a", "lib/a.ex"}) ++ [Message.tool_result("a", "read", "x")]
        )

      assert entry.id == "tool:a"
      assert entry.tool_group == nil
    end

    test "non-exploring tools, prose, and thinking break runs" do
      entries =
        settled([
          Message.assistant(
            thinking: "looking",
            tool_calls: [%{id: "a", name: "read", arguments: %{"path" => "lib/a.ex"}}]
          ),
          Message.tool_result("a", "read", "a"),
          Message.assistant(
            thinking: "more",
            tool_calls: [%{id: "b", name: "read", arguments: %{"path" => "lib/b.ex"}}]
          ),
          Message.tool_result("b", "read", "b"),
          Message.assistant(
            tool_calls: [%{id: "c", name: "read", arguments: %{"path" => "lib/c.ex"}}]
          ),
          Message.tool_result("c", "read", "c"),
          Message.assistant(
            tool_calls: [
              %{id: "d", name: "edit", arguments: %{"path" => "a", "edits" => []}},
              %{id: "e", name: "read", arguments: %{"path" => "lib/e.ex"}}
            ]
          ),
          Message.tool_result("d", "edit", "edited"),
          Message.tool_result("e", "read", "e")
        ])

      assert Enum.map(entries, &{&1.kind, &1.id}) == [
               {:thinking, "message:0:thinking"},
               {:tool, "tool:a"},
               {:thinking, "message:2:thinking"},
               {:tool, "group:tool:b"},
               {:tool, "tool:d"},
               {:tool, "tool:e"}
             ]
    end

    test "failed exploring calls stay in the group" do
      entries =
        settled(
          assistant_calls(read: {"a", "lib/a.ex"}, read: {"b", "lib/b.ex"}) ++
            [
              Message.tool_result("a", "read", "Error: no such file"),
              Message.tool_result("b", "read", "b output")
            ]
        )

      [group] = entries
      assert group.tool_status == :completed
      assert Enum.map(group.tool_group, & &1.tool_status) == [:failed, :completed]
    end

    test "live turn groups reflect the running state and keep member ids" do
      state = %{
        stream: %Tackle.CLI.TUI.State.Stream{
          timeline: [
            %{
              kind: :tool,
              id: "one",
              name: "read",
              arguments: %{"path" => "one"},
              status: :running
            },
            %{
              kind: :tool,
              id: "two",
              name: "read",
              arguments: %{"path" => "two"},
              status: :completed
            }
          ]
        }
      }

      assert [%{id: "group:tool:one", tool_status: :running} = group] =
               MessageView.section_entries(state, :turn)

      assert Enum.map(group.tool_group, & &1.id) == ["tool:one", "tool:two"]
    end
  end

  describe "group rendering" do
    test "completed groups summarize one row per call kind" do
      group =
        settled(
          assistant_calls(
            read: {"a", "lib/a.ex"},
            bash: {"b", "rg \"defmodule\" lib"},
            bash: {"c", "ls packages"}
          ) ++
            [
              Message.tool_result("a", "read", "a"),
              Message.tool_result("b", "bash", "b"),
              Message.tool_result("c", "bash", "c")
            ]
        )
        |> hd()

      text = group |> ToolView.render(80) |> text()
      assert text =~ "• Explored"
      assert text =~ "Read  a.ex"
      assert text =~ "Search  defmodule in lib"
      assert text =~ "List  packages"
      refute text =~ "Exploring"
    end

    test "consecutive completed reads merge into one row" do
      group =
        settled(
          assistant_calls(
            read: {"a", "lib/a.ex"},
            read: {"b", "lib/b.ex"},
            read: {"c", "lib/a.ex"}
          ) ++ [Message.tool_result("a", "read", "a"), Message.tool_result("b", "read", "b")]
        )
        |> hd()

      text = group |> ToolView.render(80) |> text()
      assert text =~ "Read  a.ex, b.ex"
    end

    test "failed calls keep their row and first error line" do
      group =
        settled(
          assistant_calls(read: {"a", "lib/a.ex"}, read: {"b", "lib/b.ex"}) ++
            [
              Message.tool_result("a", "read", "Error: no such file\nmore detail"),
              Message.tool_result("b", "read", "b")
            ]
        )
        |> hd()

      text = group |> ToolView.render(80) |> text()
      assert text =~ "Read  a.ex  (failed)"
      assert text =~ "└ Error: no such file"
      assert text =~ "Read  b.ex"
      refute text =~ "more detail"
    end

    test "details expand every member back into its full card" do
      group =
        settled(
          assistant_calls(read: {"a", "lib/a.ex"}, bash: {"b", "ls packages"}) ++
            [
              Message.tool_result("a", "read", "full a output"),
              Message.tool_result("b", "bash", "full b output")
            ]
        )
        |> hd()

      details = group |> MessageView.inspect_items(100) |> text()
      assert details =~ "read  lib/a.ex"
      assert details =~ "full a output"
      assert details =~ "bash  ls packages"
      assert details =~ "full b output"
    end

    test "group source, search, and copy retain every member" do
      group =
        settled(
          assistant_calls(read: {"a", "lib/a.ex"}, bash: {"b", "ls packages"}) ++
            [
              Message.tool_result("a", "read", "a output"),
              Message.tool_result("b", "bash", "b output")
            ]
        )
        |> hd()

      assert MessageView.full_text(group) == "a output\n\nb output"
      assert MessageView.search_text(group) =~ "packages"
      assert MessageView.search_text(group) =~ "b output"
      assert group.content =~ "lib/a.ex"
      assert MessageView.source_text(group) == "a output\n\nb output"
    end
  end

  defp classify(command), do: ToolGroups.classify(bash_entry(command))

  defp classify_read(path), do: ToolGroups.classify(read_entry(path))

  defp bash_entry(command) do
    [entry] =
      settled([
        Message.assistant(
          tool_calls: [%{id: "c", name: "bash", arguments: %{"command" => command}}]
        )
      ])

    entry
  end

  defp read_entry(path) do
    [entry] =
      settled([
        Message.assistant(tool_calls: [%{id: "c", name: "read", arguments: %{"path" => path}}])
      ])

    entry
  end

  defp assistant_calls(spec) do
    calls =
      Enum.with_index(spec, 1)
      |> Enum.map(fn
        {{:read, {id, path}}, _index} ->
          %{id: id, name: "read", arguments: %{"path" => path}}

        {{:bash, {id, command}}, _index} ->
          %{id: id, name: "bash", arguments: %{"command" => command}}
      end)

    [Message.assistant(tool_calls: calls)]
  end

  defp settled(messages),
    do:
      MessageView.section_entries(
        %{agent_state: %State{messages: messages}, thinking_expanded?: false},
        :settled
      )

  defp text(items) do
    Enum.map_join(items, "\n", fn {widget, _height} ->
      widget |> Map.fetch!(:text) |> plain()
    end)
  end

  defp plain(text) when is_binary(text), do: text
  defp plain(%{spans: spans}), do: Enum.map_join(spans, "", & &1.content)
  defp plain(lines) when is_list(lines), do: Enum.map_join(lines, "\n", &plain/1)
end
