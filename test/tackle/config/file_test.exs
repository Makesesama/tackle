defmodule Tackle.Config.FileTest do
  use ExUnit.Case, async: true

  alias Tackle.Config

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["default", "file", "environment", "override"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-config-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home, env: %{"TACKLE_HOME" => home}}
  end

  test "missing config file uses validator defaults and explicit overrides", %{env: env} do
    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    assert config.model_ref == "test/default"
    assert config.max_iterations == 10
  end

  test "loads model and thinking from config.json", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file","thinking":"high"}))

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/file"
    assert config.llm_opts == [reasoning_effort: "high", reasoning_summary: "auto"]
  end

  test "environment overrides the file", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file","thinking":"low"}))

    env =
      env
      |> Map.put("TACKLE_MODEL", "test/environment")
      |> Map.put("TACKLE_THINKING", "xhigh")

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/environment"
    assert config.llm_opts == [reasoning_effort: "xhigh", reasoning_summary: "auto"]
  end

  test "explicit overrides win over environment variables", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file"}))
    env = Map.put(env, "TACKLE_MODEL", "test/environment")

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/override", thinking: "medium"]
             )

    assert config.model_ref == "test/override"
    assert config.llm_opts == [reasoning_effort: "medium", reasoning_summary: "auto"]
  end

  test "invalid thinking configuration returns an explicit error", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","thinking":"extreme"}))

    assert {:error, {:invalid_config_field, ^path, "thinking"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, ~s({"model":"test/file"}))

    assert {:error, {:invalid_environment, "TACKLE_THINKING"}} =
             Config.load(
               available_adapters: [Adapter],
               env: Map.put(env, "TACKLE_THINKING", "extreme")
             )
  end

  test "unknown fields and malformed JSON return errors", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","adapter":"Elixir.System"}))

    assert {:error, {:unknown_config_fields, ^path, ["adapter"]}} =
             Config.load(available_adapters: [Adapter], env: env)

    File.write!(path, ~s({"model":))

    assert {:error, {:malformed_config_file, ^path}} =
             Config.load(available_adapters: [Adapter], env: env)
  end

  test "module-looking strings are data and are never converted to atoms", %{home: home, env: env} do
    module_name = "Elixir.UnloadedTackleAdapter#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
    path = write_config(home, JSON.encode!(%{"adapter" => module_name}))

    assert {:error, {:unknown_config_fields, ^path, ["adapter"]}} =
             Config.load(available_adapters: [Adapter], env: env)

    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "TACKLE_HOME path resolution does not consult the real home", %{home: home, env: env} do
    assert {:ok, ^home} = Tackle.Paths.home(env: env, user_home: nil)
    assert {:ok, path} = Tackle.Paths.config_file(env: env, user_home: nil)
    assert path == Path.join(home, "config.json")
  end

  test "default home is a .tackle directory under the user home" do
    user_home = Path.join(System.tmp_dir!(), "tackle-user-home")
    assert {:ok, path} = Tackle.Paths.home(env: %{}, user_home: user_home)
    assert path == Path.join(user_home, ".tackle")
  end

  test "missing user home is explicit" do
    assert {:error, :user_home_unavailable} = Tackle.Paths.home(env: %{}, user_home: nil)
  end

  defp write_config(home, contents) do
    File.mkdir_p!(home)
    path = Path.join(home, "config.json")
    File.write!(path, contents)
    path
  end
end
