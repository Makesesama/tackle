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

  test "null leaves a field unset, so a project's null removes the user's value", ctx do
    write(ctx.home, ~s({
      "model": "test/project",
      "thinking": "high",
      "decision_model": null,
      "agents": {"scout": {"model": "test/user"}, "worker": {"thinking": "low"}},
      "review": {"profile": "quiet", "thinking": {"detector": "low"}}
    }))

    write(project(ctx.repo), ~s({
      "model": null,
      "thinking": null,
      "agents": {"scout": null, "worker": {"thinking": null}},
      "review": {"thinking": {"detector": null}}
    }))

    assert {:ok, config} = load(ctx)
    # The first model of the providers, as without any configuration.
    assert config.model_ref == "test/user"
    assert Thinking.from_llm_opts(config.llm_opts) == "off"
    assert config.agents == %{"worker" => %{}}
    assert config.context.review_settings.profile == :quiet
    assert config.context.review_settings.thinking == %{}

    # A null for a field a project may not set is still refused.
    path = write(project(ctx.repo), ~s({"providers": null}))
    assert {:error, {:config_file, ^path, {:unknown_fields, ["providers"]}}} = load(ctx)
  end

  test "a project file cannot declare providers or CLI preferences", ctx do
    path = write(project(ctx.repo), ~s({"providers": {"evil": {"adapter": "test"}}}))
    assert {:error, {:config_file, ^path, {:unknown_fields, ["providers"]}}} = load(ctx)

    write(project(ctx.repo), ~s({"show_subagent_sidebar": false}))

    assert {:error, {:config_file, ^path, {:unknown_fields, ["show_subagent_sidebar"]}}} =
             load(ctx)
  end

  test "a project file cannot pass host environment variables into the jail", ctx do
    path = write(project(ctx.repo), ~s({"jail": {"env": ["AWS_SECRET_ACCESS_KEY"]}}))
    assert {:error, {:config_file, ^path, {:unknown_fields, ["jail"]}}} = load(ctx)

    # The user's own setting is kept when a project file is present.
    write(ctx.home, ~s({"jail": {"env": ["GH_TOKEN"]}}))
    write(project(ctx.repo), ~s({"model": "test/project"}))
    assert {:ok, config} = load(ctx)
    assert config.model_ref == "test/project"
  end

  test "a project file tunes or turns off the compile gate but cannot turn it on", ctx do
    # Off unless the user turned it on.
    for project <- [~s({"compile_gate": true}), ~s({"compile_gate": {"max_rounds": 1}})] do
      write(project(ctx.repo), project)
      assert {:ok, config} = load(ctx)
      assert config.compile_gate == nil
    end

    write(ctx.home, ~s({"compile_gate": true}))
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

  test "true and false switch a feature like enabled true and false, keeping its settings",
       ctx do
    write(ctx.home, ~s({
      "narration": {"model": "test/user", "interval_seconds": 3, "enabled": false},
      "session_titles": {"model": "test/user"},
      "compile_gate": {"max_rounds": 1}
    }))

    write(project(ctx.repo), ~s({"narration": true, "session_titles": false}))
    assert {:ok, config} = load(ctx)
    assert %{model_ref: "test/user", interval_seconds: 3} = config.narration
    assert config.session_titles == nil
    assert config.compile_gate.max_rounds == 1

    write(project(ctx.repo), ~s({"narration": false, "compile_gate": false}))
    assert {:ok, config} = load(ctx)
    assert config.narration == nil
    assert config.compile_gate == nil

    # Only the user turns the compile gate on, also with `true`.
    write(ctx.home, ~s({"compile_gate": {"enabled": false, "max_rounds": 1}}))
    write(project(ctx.repo), ~s({"compile_gate": true}))
    assert {:ok, %{compile_gate: nil}} = load(ctx)

    write(ctx.home, ~s({"compile_gate": true}))
    write(project(ctx.repo), ~s({"compile_gate": {"max_rounds": 0}}))
    assert {:ok, %{compile_gate: %{max_rounds: 0}}} = load(ctx)
  end

  test "project and user files are validated and reported separately", ctx do
    path = write(project(ctx.repo), ~s({"model": ""}))
    assert {:error, {:config_file, ^path, {:invalid_field, "model"}}} = load(ctx)

    write(project(ctx.repo), "{not json")
    assert {:error, {:config_file, ^path, :malformed}} = load(ctx)

    write(project(ctx.repo), ~s({"model": "test/project"}))
    user = write(ctx.home, ~s({"thinking": "extreme"}))
    assert {:error, {:config_file, ^user, {:invalid_field, "thinking"}}} = load(ctx)
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

  test "a malformed executor fails the load before any file is read", ctx do
    # Reading this project file would fail the load with another error.
    write(project(ctx.repo), "not json")

    assert {:error, {:invalid_option, :executor, {NotAModule, nil}}} =
             load(ctx, overrides: [context: %{executor: {NotAModule, nil}}])

    assert {:error, {:invalid_option, :executor, :jailed}} =
             load(ctx, overrides: [context: %{executor: :jailed}])

    assert {:error, {:invalid_option, :context, :none}} =
             load(ctx, overrides: [context: :none])

    # Nor are the accounts read.
    assert {:error, {:invalid_option, :executor, :jailed}} =
             load(ctx, overrides: [context: %{executor: :jailed}], accounts: :unread)
  end

  test "agent settings are validated against the providers", ctx do
    write(ctx.home, ~s({"model": "test/user"}))

    path = write(project(ctx.repo), ~s({"agents": {"scout": {"model": "test/missing"}}}))

    assert {:error, {:config_file, ^path, {:invalid_agent_settings, "scout", _reason}}} =
             load(ctx)

    write(project(ctx.repo), ~s({"agents": {"scout": {"thinking": "extreme"}}}))

    assert {:error,
            {:config_file, ^path,
             {:invalid_agent_settings, "scout", {:invalid_thinking_level, "extreme"}}}} =
             load(ctx)

    write(project(ctx.repo), ~s({"agents": {"scout": {"tools": ["bash"]}}}))
    assert {:error, {:config_file, ^path, {:invalid_agent, "scout"}}} = load(ctx)

    write(project(ctx.repo), ~s({"agents": ["scout"]}))
    assert {:error, {:config_file, ^path, {:invalid_field, "agents"}}} = load(ctx)
  end

  test "an invalid value is reported with the file that set it", ctx do
    user = write(ctx.home, ~s({"model": "test/user", "narration": {"model": "test/missing"}}))
    path = write(project(ctx.repo), ~s({"narration": {"interval_seconds": 3}}))

    # Both files set narration; the user's value fails on its own.
    assert {:error, {:config_file, ^user, {:unknown_model, "test/missing"}}} = load(ctx)

    # The user's value is valid, so the project's made the merged value fail.
    write(ctx.home, ~s({"model": "test/user", "narration": {"model": "test/user"}}))
    write(project(ctx.repo), ~s({"narration": {"interval_seconds": 0}}))

    assert {:error, {:config_file, ^path, {:invalid_option, :narration, interval_seconds: 0}}} =
             load(ctx)

    # A value only one file sets names that file.
    write(project(ctx.repo), ~s({"model": "test/missing"}))
    assert {:error, {:config_file, ^path, {:unknown_model, "test/missing"}}} = load(ctx)

    write(project(ctx.repo), ~s({}))
    write(ctx.home, ~s({"session_titles": {"model": "test/missing"}}))
    assert {:error, {:config_file, ^user, {:unknown_model, "test/missing"}}} = load(ctx)

    # A value from the environment or the overrides names no file, and the
    # files' values it replaces are not checked.
    write(ctx.home, ~s({"model": "test/missing"}))
    env = Map.put(ctx.env, "TACKLE_MODEL", "test/gone")
    assert {:error, {:unknown_model, "test/gone"}} = load(%{ctx | env: env})
    assert {:error, {:unknown_model, "test/gone"}} = load(ctx, overrides: [model: "test/gone"])
    assert {:ok, %{model_ref: "test/user"}} = load(ctx, overrides: [model: "test/user"])
  end
end
