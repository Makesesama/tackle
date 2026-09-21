defmodule Tackle.Web.PathsTest do
  # Mutates process-global environment and application config.
  use ExUnit.Case, async: false

  alias Tackle.Web.Paths

  @config_keys [:data_root, :repos_root, :lumis_data_dir]
  @env_vars ["TACKLE_WEB_DATA_ROOT", "TACKLE_WEB_REPOS_ROOT", "TACKLE_WEB_LUMIS_DATA_DIR"]

  setup do
    saved_config = Map.new(@config_keys, &{&1, Application.get_env(:tackle_web, &1)})
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})

    Enum.each(@config_keys, &Application.delete_env(:tackle_web, &1))
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@config_keys, fn key ->
        case saved_config[key] do
          nil -> Application.delete_env(:tackle_web, key)
          value -> Application.put_env(:tackle_web, key, value)
        end
      end)

      Enum.each(@env_vars, fn var ->
        case saved_env[var] do
          nil -> System.delete_env(var)
          value -> System.put_env(var, value)
        end
      end)
    end)
  end

  describe "defaults" do
    test "derive every path from the data root" do
      assert Paths.data_root() == "/var/tackle_web"
      assert Paths.repos_root() == "/var/tackle_web/repos"
      assert Paths.lumis_data_dir() == "/var/tackle_web/lumis"
    end

    test "the data root defaults outside the source tree" do
      source_tree = Path.expand("../..", __DIR__)

      refute String.starts_with?(Paths.repos_root(), source_tree)
      refute String.starts_with?(Paths.lumis_data_dir(), source_tree)
    end
  end

  describe "data_root/0" do
    test "honours application config" do
      Application.put_env(:tackle_web, :data_root, "/srv/data")

      assert Paths.data_root() == "/srv/data"
      assert Paths.repos_root() == "/srv/data/repos"
      assert Paths.lumis_data_dir() == "/srv/data/lumis"
    end

    test "honours the environment" do
      System.put_env("TACKLE_WEB_DATA_ROOT", "/env/data")

      assert Paths.data_root() == "/env/data"
      assert Paths.repos_root() == "/env/data/repos"
    end

    test "the environment wins over application config" do
      Application.put_env(:tackle_web, :data_root, "/srv/data")
      System.put_env("TACKLE_WEB_DATA_ROOT", "/env/data")

      assert Paths.data_root() == "/env/data"
    end

    test "a blank override is treated as unset" do
      System.put_env("TACKLE_WEB_DATA_ROOT", "")

      assert Paths.data_root() == "/var/tackle_web"
    end
  end

  describe "repos_root/0" do
    test "resolves independently of the data root" do
      Application.put_env(:tackle_web, :repos_root, "/mnt/big/repos")

      assert Paths.repos_root() == "/mnt/big/repos"
      assert Paths.data_root() == "/var/tackle_web"
      assert Paths.lumis_data_dir() == "/var/tackle_web/lumis"
    end

    test "can be pointed at the environment" do
      System.put_env("TACKLE_WEB_REPOS_ROOT", "/env/repos")

      assert Paths.repos_root() == "/env/repos"
    end
  end

  describe "lumis_data_dir/0" do
    test "resolves independently of the data root" do
      Application.put_env(:tackle_web, :lumis_data_dir, "/local/lumis")

      assert Paths.lumis_data_dir() == "/local/lumis"
      assert Paths.repos_root() == "/var/tackle_web/repos"
    end

    test "can be pointed at the environment" do
      System.put_env("TACKLE_WEB_LUMIS_DATA_DIR", "/env/lumis")

      assert Paths.lumis_data_dir() == "/env/lumis"
    end
  end

  describe "repo_path/2" do
    test "joins the repos root with the owner and repository name" do
      Application.put_env(:tackle_web, :repos_root, "/srv/repos")

      assert Paths.repo_path("elixir-lang", "elixir") == "/srv/repos/elixir-lang/elixir"
    end

    test "keeps distinct repositories apart" do
      refute Paths.repo_path("a", "b") == Paths.repo_path("a", "b-c")
    end
  end

  describe "ensure_dir!/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "tackle_web_paths_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "creates missing parents and returns the path", %{dir: dir} do
      nested = Path.join([dir, "owner", "name"])

      assert Paths.ensure_dir!(nested) == nested
      assert File.dir?(nested)
    end

    test "is idempotent", %{dir: dir} do
      assert Paths.ensure_dir!(dir) == dir
      assert Paths.ensure_dir!(dir) == dir
    end

    test "accepts the result of repo_path/2", %{dir: dir} do
      Application.put_env(:tackle_web, :repos_root, dir)

      path = Paths.repo_path("owner", "name")

      assert Paths.ensure_dir!(path) == path
      assert File.dir?(path)
    end

    test "raises with an actionable message when the path is not creatable", %{dir: dir} do
      File.write!(dir, "this is a file, not a directory")

      error =
        assert_raise RuntimeError, fn ->
          Paths.ensure_dir!(Path.join(dir, "nested"))
        end

      message = Exception.message(error)
      assert message =~ "Could not create the runtime data directory"
      assert message =~ "TACKLE_WEB_DATA_ROOT"
      assert message =~ Path.join(dir, "nested")
    end
  end
end
