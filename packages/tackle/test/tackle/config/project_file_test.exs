defmodule Tackle.Config.ProjectFileTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Lib.Thinking
  alias Tackle.Test.FakeJail

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["user", "project", "environment", "child"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  # The user's TACKLE_HOME lives outside the repository; the repository is a
  # Git root containing a nested working directory.
  setup do
    root =
      Path.join(System.tmp_dir!(), "tackle-project-config-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    cwd = Path.join(repo, "apps/cli")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(repo, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, home: home, repo: repo, cwd: cwd, env: %{"TACKLE_HOME" => home}}
  end

  defp load(%{env: env, cwd: cwd}, opts \\ []),
    do: Config.load([available_adapters: [Adapter], env: env, cwd: cwd] ++ opts)

  defp write(dir, contents) do
    path = Path.join(dir, "config.json")
    File.mkdir_p!(dir)
    File.write!(path, contents)
    path
  end

  defp project(dir), do: Path.join(dir, ".tackle")

  test "the project file layers over the user file, and the environment over both", ctx do
    write(ctx.home, ~s({"model": "test/user", "thinking": "low"}))
    write(project(ctx.repo), ~s({"model": "test/project"}))

    assert {:ok, config} = load(ctx)
    assert config.model_ref == "test/project"
    assert Thinking.from_llm_opts(config.llm_opts) == "low"

    assert {:ok, config} =
             load(%{ctx | env: Map.put(ctx.env, "TACKLE_MODEL", "test/environment")})

    assert config.model_ref == "test/environment"

    assert {:ok, config} = load(ctx, overrides: [model: "test/child"])
    assert config.model_ref == "test/child"
  end

  test "the nearest project file wins and the search stops at the Git root", ctx do
    write(project(ctx.root), ~s({"model": "test/child"}))
    write(ctx.home, ~s({"model": "test/user"}))
    assert {:ok, %{model_ref: "test/user"}} = load(ctx)

    write(project(ctx.repo), ~s({"model": "test/project"}))
    write(project(ctx.cwd), ~s({"thinking": "high"}))
    assert {:ok, config} = load(ctx)
    assert config.model_ref == "test/user"
    assert Thinking.from_llm_opts(config.llm_opts) == "high"
  end

  test "objects merge recursively; project values replace user values", ctx do
    write(ctx.home, ~s({
      "model": "test/user",
      "review": {"profile": "quiet", "models": {"detector": "test/user", "verifier": "test/user"}},
      "agents": {"scout": {"model": "test/user", "thinking": "low"}, "worker": {"model": "test/user"}}
    }))

    write(project(ctx.repo), ~s({
      "review": {"models": {"verifier": "test/project"}},
      "agents": {"scout": {"thinking": "high"}, "worker": {"model": null}}
    }))

    assert {:ok, config} = load(ctx)
    assert config.review.profile == :quiet
    assert config.review.models == %{detector: "test/user", verifier: "test/project"}

    assert config.agents == %{
             "scout" => %{model: "test/user", thinking: "high"},
             "worker" => %{}
           }
  end

  test "a project file cannot declare providers or CLI preferences", ctx do
    path = write(project(ctx.repo), ~s({"providers": {"evil": {"adapter": "test"}}}))
    assert {:error, {:unknown_config_fields, ^path, ["providers"]}} = load(ctx)

    write(project(ctx.repo), ~s({"show_subagent_sidebar": false}))
    assert {:error, {:unknown_config_fields, ^path, ["show_subagent_sidebar"]}} = load(ctx)
  end

  test "a project file tunes the compile gate but cannot turn it back on", ctx do
    write(project(ctx.repo), ~s({"compile_gate": {"max_rounds": 1}}))
    assert {:ok, config} = load(ctx)
    assert config.compile_gate.max_rounds == 1

    write(ctx.home, ~s({"compile_gate": false}))
    assert {:ok, config} = load(ctx)
    assert config.compile_gate == nil

    write(ctx.home, ~s({"compile_gate": {"enabled": false}}))
    write(project(ctx.repo), ~s({"compile_gate": {"enabled": true, "max_rounds": 1}}))
    assert {:ok, config} = load(ctx)
    assert config.compile_gate == nil

    write(ctx.home, ~s({"compile_gate": {"max_rounds": 3}}))
    write(project(ctx.repo), ~s({"compile_gate": false}))
    assert {:ok, config} = load(ctx)
    assert config.compile_gate == nil
  end

  test "project and user files are validated and reported separately", ctx do
    path = write(project(ctx.repo), ~s({"model": ""}))
    assert {:error, {:invalid_config_field, ^path, "model"}} = load(ctx)

    write(project(ctx.repo), "{not json")
    assert {:error, {:malformed_config_file, ^path}} = load(ctx)

    write(project(ctx.repo), ~s({"model": "test/project"}))
    user = write(ctx.home, ~s({"thinking": "extreme"}))
    assert {:error, {:invalid_config_field, ^user, "thinking"}} = load(ctx)
  end

  test "outside a repository the user file is not read again as a project file", ctx do
    # TACKLE_HOME is the default `<user home>/.tackle`, an ancestor of the cwd.
    tackle_home = project(ctx.root)
    write(tackle_home, ~s({"model": "test/user", "providers": {}}))
    cwd = Path.join(ctx.root, "scratch")
    File.mkdir_p!(cwd)

    assert {:ok, %{model_ref: "test/user"}} =
             load(%{ctx | cwd: cwd, env: %{"TACKLE_HOME" => tackle_home}})

    # Also when TACKLE_HOME names that directory through a symlink.
    linked_home = Path.join(ctx.root, "linked-home")
    File.ln_s!(tackle_home, linked_home)

    assert {:ok, %{model_ref: "test/user"}} =
             load(%{ctx | cwd: cwd, env: %{"TACKLE_HOME" => linked_home}})
  end

  test "the project file is read through the session executor", ctx do
    secret = write(Path.join(ctx.root, "secret"), ~s({"model": "test/child"}))
    File.mkdir_p!(project(ctx.repo))
    File.ln_s!(secret, Path.join(project(ctx.repo), "config.json"))
    write(ctx.home, ~s({"model": "test/user"}))

    assert {:ok, %{model_ref: "test/child"}} = load(ctx)

    jail = FakeJail.new(ctx.repo)
    assert {:ok, config} = load(ctx, overrides: [context: %{executor: jail}])
    assert config.model_ref == "test/user"
  end

  test "agent settings are validated against the providers", ctx do
    write(ctx.home, ~s({"model": "test/user"}))

    write(project(ctx.repo), ~s({"agents": {"scout": {"model": "test/missing"}}}))
    assert {:error, {:invalid_agent_settings, "scout", _reason}} = load(ctx)

    write(project(ctx.repo), ~s({"agents": {"scout": {"thinking": "extreme"}}}))

    assert {:error, {:invalid_agent_settings, "scout", {:invalid_thinking_level, "extreme"}}} =
             load(ctx)

    path = write(project(ctx.repo), ~s({"agents": {"scout": {"tools": ["bash"]}}}))
    assert {:error, {:invalid_config_agent, ^path, "scout"}} = load(ctx)

    write(project(ctx.repo), ~s({"agents": ["scout"]}))
    assert {:error, {:invalid_config_field, ^path, "agents"}} = load(ctx)
  end
end
