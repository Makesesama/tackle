defmodule Tackle.AgentsTest do
  use ExUnit.Case, async: true

  alias Tackle.Agents

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-agents-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    tackle_home = Path.join(root, "tackle-home")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      project: Path.join(cwd, ".tackle/agents"),
      opts: [cwd: cwd, env: %{"TACKLE_HOME" => tackle_home}, builtins: []]
    }
  end

  describe "tools" do
    test "reads quoted flow and block lists", %{project: project, opts: opts} do
      put(project, "flow.md", agent("flow", ~s(tools: ["read", 'bash'])))
      put(project, "block.md", agent("block", "tools:\n  - \"read\"\n  - bash"))
      put(project, "plain.md", agent("plain", "tools: read, bash"))

      assert %{definitions: definitions, warnings: []} = Agents.discover(opts)

      assert Map.new(definitions, &{&1.name, &1.tools}) == %{
               "block" => ["read", "bash"],
               "flow" => ["read", "bash"],
               "plain" => ["read", "bash"]
             }
    end

    test "an empty value leaves tools unset, an empty list selects none", %{
      project: project,
      opts: opts
    } do
      put(project, "empty.md", agent("empty", "tools:"))
      put(project, "none.md", agent("none", "tools: []"))

      assert %{definitions: [empty, none], warnings: []} = Agents.discover(opts)
      assert {empty.name, empty.tools} == {"empty", nil}
      assert {none.name, none.tools} == {"none", []}
    end

    test "malformed and duplicate lists are rejected", %{project: project, opts: opts} do
      put(project, "malformed.md", agent("malformed", ~s(tools: ["read" bash])))
      put(project, "twice.md", agent("twice", ~s(tools: [read, "read"])))

      assert %{definitions: [], warnings: [malformed, twice]} = Agents.discover(opts)
      assert malformed.message =~ "tools must be a flow, block, or comma-separated list"
      assert twice.message == "tools contains duplicate names"
    end
  end

  test "a whitespace-only description is rejected", %{project: project, opts: opts} do
    put(project, "blank.md", "---\nname: blank\ndescription: \"   \"\n---\nPrompt.\n")

    assert %{definitions: [], warnings: [%{message: "description is required"}]} =
             Agents.discover(opts)
  end

  test "timeoutMs above five minutes is an error naming the agent and the limit", %{
    project: project,
    opts: opts
  } do
    put(project, "slow.md", agent("slow", "timeoutMs: 300001"))
    put(project, "limit.md", agent("limit", "timeoutMs: 300000"))

    assert %{definitions: [%{name: "limit", timeout: 300_000}], warnings: [warning]} =
             Agents.discover(opts)

    assert warning.path == Path.join(project, "slow.md")

    assert warning.message ==
             "timeoutMs of agent slow is 300001; the limit is 300000 (five minutes)"
  end

  describe "the project search" do
    test "without a Git root, does not climb above the home directory", %{root: root} do
      # Any local user can write a shared parent such as /tmp.
      put(Path.join(root, ".tackle/agents"), "planted.md", agent("planted", ""))
      cwd = Path.join(root, "scratch/work")
      File.mkdir_p!(cwd)
      env = %{"TACKLE_HOME" => Path.join(root, "tackle-home")}

      assert Agents.discover(cwd: cwd, env: env, builtins: []).definitions == []

      home = Path.join(root, "scratch")
      put(Path.join(home, ".tackle/agents"), "own.md", agent("own", ""))

      assert [%{name: "own", source: :project}] =
               Agents.discover(cwd: cwd, env: Map.put(env, "HOME", home), builtins: []).definitions
    end
  end

  defp agent(name, extra) do
    "---\nname: #{name}\ndescription: The #{name} agent\n#{extra}\n---\nDo the #{name} work.\n"
  end

  defp put(dir, name, contents) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), contents)
  end
end
