defmodule Tackle.AgentsTest do
  use ExUnit.Case, async: true

  alias Tackle.Agents
  alias Tackle.Agents.Definition

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
      opts: [cwd: cwd, home: tackle_home, user_home: nil, builtins: []]
    }
  end

  describe "tools" do
    test "reads quoted flow and block lists", %{project: project, opts: opts} do
      put(project, "flow.md", agent("flow", ~s(tools: ["read", 'bash'])))
      put(project, "block.md", agent("block", "tools:\n  - \"read\"\n  - bash"))
      put(project, "plain.md", agent("plain", "tools: read, bash"))

      assert {:ok, definitions} = Agents.discover(opts)

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

      assert {:ok, [empty, none]} = Agents.discover(opts)
      assert {empty.name, empty.tools} == {"empty", nil}
      assert {none.name, none.tools} == {"none", []}
    end

    test "malformed and duplicate lists are rejected", %{project: project, opts: opts} do
      put(project, "malformed.md", agent("malformed", ~s(tools: ["read" bash])))
      put(project, "twice.md", agent("twice", ~s(tools: [read, "read"])))

      assert {:error, {:invalid_agent_definitions, [malformed, twice]}} = Agents.discover(opts)
      assert malformed.message =~ "tools must be a flow, block, or comma-separated list"
      assert twice.message == "tools contains duplicate names"
    end
  end

  test "a whitespace-only description is rejected", %{project: project, opts: opts} do
    put(project, "blank.md", "---\nname: blank\ndescription: \"   \"\n---\nPrompt.\n")

    assert {:error, {:invalid_agent_definitions, [%{message: "description is required"}]}} =
             Agents.discover(opts)
  end

  test "timeoutMs above five minutes is an error naming the agent and the limit", %{
    project: project,
    opts: opts
  } do
    put(project, "limit.md", agent("limit", "timeoutMs: 300000"))
    assert {:ok, [%{name: "limit", timeout: 300_000}]} = Agents.discover(opts)

    put(project, "slow.md", agent("slow", "timeoutMs: 300001"))
    assert {:error, {:invalid_agent_definitions, [warning]}} = Agents.discover(opts)
    assert warning.path == Path.join(project, "slow.md")

    assert warning.message ==
             "timeoutMs of agent slow is 300001; the limit is 300000 (five minutes)"
  end

  describe "the project search" do
    test "never reads $TACKLE_HOME as the project directory", %{root: root} do
      # The default layout: $TACKLE_HOME is ~/.tackle and the working
      # directory is under ~, outside any Git repository.
      cwd = Path.join(root, "notes")
      File.mkdir_p!(cwd)
      put(Path.join(root, ".tackle/agents"), "mine.md", agent("mine", ""))

      opts = [
        cwd: cwd,
        home: Path.join(root, ".tackle"),
        user_home: root,
        builtins: []
      ]

      assert {:ok, [%{name: "mine", source: :user}]} = Agents.discover(opts)
      assert {:ok, [%{source: :user}]} = Agents.discover(Keyword.put(opts, :cwd, root))
    end

    test "without a Git root, does not climb above the home directory", %{root: root} do
      # Any local user can write a shared parent such as /tmp.
      put(Path.join(root, ".tackle/agents"), "planted.md", agent("planted", ""))
      cwd = Path.join(root, "scratch/work")
      File.mkdir_p!(cwd)
      opts = [cwd: cwd, home: Path.join(root, "tackle-home"), user_home: nil, builtins: []]

      assert Agents.discover(opts) == {:ok, []}

      home = Path.join(root, "scratch")
      put(Path.join(home, ".tackle/agents"), "own.md", agent("own", ""))

      assert {:ok, [%{name: "own", source: :project}]} =
               Agents.discover(Keyword.put(opts, :user_home, home))
    end

    test "uses the nearest project directory, recursively, and stops at the Git root", %{
      root: root,
      cwd: cwd,
      project: project,
      opts: opts
    } do
      put(Path.join(root, ".tackle/agents"), "outside.md", agent("outside", ""))
      assert Agents.discover(opts) == {:ok, []}

      put(Path.join(project, "nested"), "scout.md", agent("scout", ""))
      child = Path.join(cwd, "child")
      File.mkdir_p!(child)
      child_opts = Keyword.put(opts, :cwd, child)
      assert {:ok, [%{name: "scout", source: :project}]} = Agents.discover(child_opts)

      File.mkdir_p!(Path.join(child, ".tackle/agents"))
      assert Agents.discover(child_opts) == {:ok, []}
    end
  end

  describe "fields" do
    test "unknown fields are rejected, naming them", %{project: project, opts: opts} do
      put(project, "odd.md", agent("odd", "colour: blue
shape: round"))

      assert {:error, {:invalid_agent_definitions, [problem]}} = Agents.discover(opts)
      assert problem == %{path: Path.join(project, "odd.md"), message: unknown("colour, shape")}
    end

    test "thinking needs an explicit model", %{project: project, opts: opts} do
      put(project, "deep.md", agent("deep", "thinking: high"))

      assert {:error, {:invalid_agent_definitions, [%{message: message}]}} =
               Agents.discover(opts)

      assert message == "thinking requires an explicit model"

      put(project, "deep.md", agent("deep", "model: fake/model\nthinking: high"))
      assert {:ok, [%{model: "fake/model", thinking: "high"}]} = Agents.discover(opts)
    end

    test "integers are positive and whole", %{project: project, opts: opts} do
      put(project, "bounded.md", agent("bounded", "maxIterations: 3\ntimeoutMs: 1000"))
      assert {:ok, [%{max_iterations: 3, timeout: 1000}]} = Agents.discover(opts)

      put(project, "defaults.md", agent("defaults", ""))
      assert {:ok, [_bounded, defaults]} = Agents.discover(opts)
      assert {defaults.max_iterations, defaults.timeout} == {:infinity, 300_000}

      File.rm!(Path.join(project, "defaults.md"))

      for value <- ["0", "-1", "3x", "1.5"] do
        put(project, "bounded.md", agent("bounded", "maxIterations: #{value}"))

        assert {:error, {:invalid_agent_definitions, [%{message: message}]}} =
                 Agents.discover(opts)

        assert message == "maxIterations must be a positive integer"
      end
    end

    test "booleans must be true or false", %{project: project, opts: opts} do
      put(project, "flag.md", agent("flag", "advertise: yes"))

      assert {:error, {:invalid_agent_definitions, [%{message: message}]}} =
               Agents.discover(opts)

      assert message == ~s(advertise must be true or false, got: "yes")
    end

    test "names and descriptions are trimmed, descriptions collapse whitespace", %{
      project: project,
      opts: opts
    } do
      put(
        project,
        "spaced.md",
        ~s(---\nname: "  spaced "\ndescription: "  Does   it\tall "\n---\nGo.\n)
      )

      assert {:ok, [%{name: "spaced", description: "Does it all", prompt: "Go."}]} =
               Agents.discover(opts)
    end

    test "names use lowercase letters, numbers, and single hyphens", %{
      project: project,
      opts: opts
    } do
      for name <- ["Upper", "two--hyphens", "-leading", "snake_case"] do
        put(project, "bad.md", agent(name, ""))

        assert {:error, {:invalid_agent_definitions, [%{message: message}]}} =
                 Agents.discover(opts)

        assert message == "name must use lowercase letters, numbers, and single hyphens"
      end
    end

    test "a blank prompt is rejected", %{project: project, opts: opts} do
      put(project, "empty.md", "---\nname: empty\ndescription: Empty\n---\n  \n\n")

      assert {:error, {:invalid_agent_definitions, [%{message: "agent prompt is required"}]}} =
               Agents.discover(opts)
    end
  end

  describe "precedence" do
    test "a name defined twice in one source is a problem; any problem fails discovery", %{
      project: project,
      opts: opts
    } do
      put(project, "a.md", agent("same", ""))
      put(Path.join(project, "nested"), "b.md", agent("same", ""))
      put(project, "fine.md", agent("fine", ""))

      assert {:error, {:invalid_agent_definitions, [problem]}} = Agents.discover(opts)

      assert problem == %{
               path: Path.join(project, "nested/b.md"),
               message: "agent name same is already defined in #{Path.join(project, "a.md")}"
             }
    end

    test "project definitions replace user definitions, which replace built-ins", %{
      project: project,
      opts: opts
    } do
      builtin = %Definition{name: "scout", description: "Built in", prompt: "P", source: :builtin}
      opts = Keyword.put(opts, :builtins, [builtin, %{builtin | name: "worker"}])
      put(Path.join(opts[:home], "agents"), "scout.md", agent("scout", ""))
      put(Path.join(opts[:home], "agents"), "worker.md", agent("worker", ""))
      put(project, "scout.md", agent("scout", ""))

      assert {:ok, [scout, worker]} = Agents.discover(opts)
      assert {scout.name, scout.source} == {"scout", :project}
      assert {worker.name, worker.source} == {"worker", :user}
    end
  end

  describe "format_for_prompt/1" do
    test "lists advertised definitions by name, escaped" do
      definitions = [
        %Definition{
          name: "zeta",
          description: "Z & <b>",
          prompt: "P",
          source: :user,
          advertise: true
        },
        %Definition{name: "hidden", description: "H", prompt: "P", source: :user},
        %Definition{
          name: "alpha",
          description: "A > B",
          prompt: "P",
          source: :user,
          advertise: true
        }
      ]

      assert Agents.format_for_prompt(definitions) == """
             <available_subagents>
               <subagent>
                 <name>alpha</name>
                 <description>A &gt; B</description>
               </subagent>
               <subagent>
                 <name>zeta</name>
                 <description>Z &amp; &lt;b&gt;</description>
               </subagent>
             </available_subagents>\
             """
    end

    test "is empty without advertised definitions" do
      hidden = %Definition{name: "hidden", description: "H", prompt: "P", source: :user}
      assert Agents.format_for_prompt([hidden]) == ""
      assert Agents.format_for_prompt([]) == ""
    end
  end

  defp agent(name, extra) do
    "---\nname: #{name}\ndescription: The #{name} agent\n#{extra}\n---\nDo the #{name} work.\n"
  end

  defp unknown(fields), do: "unknown frontmatter fields: #{fields}"

  defp put(dir, name, contents) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), contents)
  end
end
