defmodule Tackle.CLI.MCPTest do
  use ExUnit.Case, async: false
  import Bitwise
  import ExUnit.CaptureIO

  alias Tackle.CLI.MCP
  alias Tackle.CLI.MCP.Config

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-mcp-cli-#{System.unique_integer([:positive])}")
    previous = System.get_env("TACKLE_HOME")
    System.put_env("TACKLE_HOME", home)

    on_exit(fn ->
      if previous,
        do: System.put_env("TACKLE_HOME", previous),
        else: System.delete_env("TACKLE_HOME")

      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "add/list/remove validate and persist only definitions", %{home: home} do
    assert capture_io(fn ->
             assert 0 ==
                      MCP.add(%{
                        name: "docs",
                        http: "https://mcp.example/mcp",
                        stdio: nil,
                        args: []
                      })
           end) =~ "Added"

    assert {:ok, %{"docs" => %{"transport" => "http"}}} = Config.list()
    assert capture_io(fn -> assert 0 == MCP.list() end) =~ "docs\thttp\thttps://mcp.example/mcp"
    assert {:ok, path} = Config.path()
    assert (File.stat!(path).mode &&& 0o777) == 0o600

    assert {:error, :mcp_server_exists} =
             Config.put("docs", %{"transport" => "http", "url" => "https://x.test"})

    assert {:error, :invalid_mcp_definition} =
             Config.put("bad", %{"transport" => "http", "url" => "http://evil.example"})

    assert capture_io(fn -> assert 0 == MCP.remove("docs") end) =~ "Removed"
    assert {:ok, %{}} = Config.list()
    refute File.exists?(Path.join(home, "auth.json"))
  end

  test "rejects malformed and linked config files" do
    {:ok, path} = Config.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json")
    assert {:error, :invalid_mcp_config} = Config.list()
    File.rm!(path)
    File.ln_s!("/tmp/something", path)

    assert {:error, :unsafe_mcp_config} =
             Config.put("x", %{"transport" => "stdio", "command" => "echo", "args" => []})
  end

  describe "project layer" do
    setup do
      project =
        Path.join(System.tmp_dir!(), "tackle-mcp-project-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(project, ".git"))
      on_exit(fn -> File.rm_rf!(project) end)
      {:ok, project: project}
    end

    test "approved project definitions replace user ones", %{project: project} do
      user = %{"transport" => "stdio", "command" => "user-server", "args" => []}
      shared = %{"transport" => "stdio", "command" => "./bin/server", "args" => ["-v"]}
      :ok = Config.put("shared", user)
      :ok = Config.put("personal", user)
      mcp_json = Path.join(project, ".tackle/mcp.json")
      File.mkdir_p!(Path.dirname(mcp_json))
      File.write!(mcp_json, JSON.encode!(%{"version" => 1, "servers" => %{"shared" => shared}}))

      # Pending: the user's own `shared` stays active next to the project entry.
      assert {:ok, [personal, user_shared, pending]} =
               Config.effective(cwd: Path.join(project, "a/b"))

      assert %{name: "personal", scope: :user, approved: true} = personal
      assert %{name: "shared", scope: :user, approved: true, definition: ^user} = user_shared

      assert %{
               name: "shared",
               scope: :project,
               approved: false,
               path: ^mcp_json,
               definition: ^shared,
               spec: %{"cwd" => ^project, "command" => "./bin/server"}
             } = pending

      assert :ok = Config.approve(mcp_json, "shared", shared)

      assert {:ok, [_, %{name: "shared", scope: :project, approved: true}]} =
               Config.effective(cwd: project)

      # Jailed sessions never run project STDIO servers on the host.
      assert {:ok, [_, %{scope: :user, approved: true}, %{blocked: :jailed, approved: false}]} =
               Config.effective(cwd: project, jailed: true)

      # Approval is bound to the project file path as well as the definition.
      other =
        Path.join(System.tmp_dir!(), "tackle-mcp-other-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(other) end)
      File.mkdir_p!(Path.join(other, ".git"))
      File.cp_r!(Path.join(project, ".tackle"), Path.join(other, ".tackle"))

      assert {:ok, [_, %{scope: :user}, %{scope: :project, approved: false}]} =
               Config.effective(cwd: other)

      assert {:ok, [%{scope: :user}, %{scope: :user}]} =
               Config.effective(cwd: project, project: false)
    end

    test "a broken project file does not block managing user servers", %{project: project} do
      :ok = Config.put("personal", %{"transport" => "http", "url" => "https://x.test/mcp"})
      File.mkdir_p!(Path.join(project, ".tackle"))
      File.write!(Path.join(project, ".tackle/mcp.json"), "not json")

      File.cd!(project, fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert capture_io(fn -> assert 0 == MCP.list() end) =~ "personal\thttp"
          end)

        assert stderr =~ "Ignoring project MCP servers"
      end)
    end

    test "rejects control characters and a symlinked .tackle", %{project: project} do
      assert {:error, :invalid_mcp_definition} =
               Config.put_project(
                 "x",
                 %{"transport" => "stdio", "command" => "sh", "args" => ["ok\rhidden"]},
                 cwd: project
               )

      elsewhere = Path.join(project, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.ln_s!(elsewhere, Path.join(project, ".tackle"))

      assert {:error, :unsafe_mcp_config} =
               Config.put_project(
                 "x",
                 %{"transport" => "stdio", "command" => "sh", "args" => []},
                 cwd: project
               )

      refute File.exists?(Path.join(elsewhere, "mcp.json"))
    end

    test "add, approve, list and remove through the CLI", %{project: project} do
      File.cd!(project, fn ->
        assert capture_io(fn ->
                 assert 0 ==
                          MCP.add(%{
                            name: "local",
                            stdio: "npx",
                            http: nil,
                            args: ["server", "a b"],
                            project: true
                          })
               end) =~ "Added project MCP server local"

        mcp_json = Path.join(File.cwd!(), ".tackle/mcp.json")

        assert %{"servers" => %{"local" => %{"command" => "npx"}}} =
                 mcp_json |> File.read!() |> JSON.decode!()

        assert capture_io(fn -> assert 0 == MCP.list() end) =~
                 ~s(local\tstdio\tnpx server "a b"\tproject\n)

        :ok = Config.revoke(mcp_json, "local")
        assert capture_io(fn -> MCP.list() end) =~ "project (not approved)"

        # Declining leaves it unapproved; the definition is shown first.
        output =
          capture_io(:stderr, fn ->
            assert capture_io(fn -> assert 1 == MCP.approve("local", fn _ -> false end) end) =~
                     ~s(npx server "a b")
          end)

        assert output =~ "aborted"
        assert capture_io(fn -> MCP.list() end) =~ "project (not approved)"

        assert capture_io(fn -> assert 0 == MCP.approve("local", fn _ -> true end) end) =~
                 "Approved"

        assert capture_io(fn -> MCP.list() end) =~ "\tproject\n"

        assert capture_io(:stderr, fn -> assert 1 == MCP.approve("missing") end) =~
                 "mcp_project_server_missing"

        assert capture_io(fn -> assert 0 == MCP.remove(%{name: "local", project: true}) end) =~
                 "Removed project MCP server local"

        assert {:ok, []} = Config.effective()
        assert {:ok, %{}} = Config.approvals()
      end)
    end

    test "a new project file goes to the Git root, not the subdirectory", %{project: project} do
      sub = Path.join(project, "a/b")
      File.mkdir_p!(sub)
      expected = Path.join(project, ".tackle/mcp.json")
      assert {:ok, %{path: ^expected, root: ^project}} = Config.project(cwd: sub)

      assert {:ok, ^expected} =
               Config.put_project(
                 "x",
                 %{"transport" => "stdio", "command" => "x", "args" => []},
                 cwd: sub
               )
    end

    test "TACKLE_HOME is never treated as a project layer" do
      root = Path.join(System.tmp_dir!(), "tackle-mcp-home-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      home = Path.join(root, ".tackle")
      File.mkdir_p!(home)
      System.put_env("TACKLE_HOME", home)
      assert :none = Config.project(cwd: Path.join(root, "work"))
      assert {:ok, nil} = Config.list_project(cwd: Path.join(root, "work"))
    end
  end

  describe "login client credentials" do
    setup do
      previous = System.get_env("TACKLE_MCP_CLIENT_SECRET")
      System.delete_env("TACKLE_MCP_CLIENT_SECRET")

      on_exit(fn ->
        if previous,
          do: System.put_env("TACKLE_MCP_CLIENT_SECRET", previous),
          else: System.delete_env("TACKLE_MCP_CLIENT_SECRET")
      end)
    end

    test "uses dynamic registration without a client id" do
      assert {:ok, [client_id: nil, client_secret: nil]} =
               MCP.client_credentials(%{client_id: nil, client_secret: nil})

      System.put_env("TACKLE_MCP_CLIENT_SECRET", "ignored")

      assert {:ok, [client_id: nil, client_secret: nil]} =
               MCP.client_credentials(%{client_id: "", client_secret: ""})
    end

    test "passes a pre-registered client id with its secret" do
      assert {:ok, [client_id: "app", client_secret: nil]} =
               MCP.client_credentials(%{client_id: "app", client_secret: nil})

      assert {:ok, [client_id: "app", client_secret: "flag"]} =
               MCP.client_credentials(%{client_id: "app", client_secret: "flag"})

      System.put_env("TACKLE_MCP_CLIENT_SECRET", "env")

      assert {:ok, [client_id: "app", client_secret: "env"]} =
               MCP.client_credentials(%{client_id: "app", client_secret: nil})

      assert {:ok, [client_id: "app", client_secret: "flag"]} =
               MCP.client_credentials(%{client_id: "app", client_secret: "flag"})
    end

    test "rejects a secret without a client id before starting the flow" do
      assert {:error, :client_secret_requires_client_id} =
               MCP.client_credentials(%{client_id: nil, client_secret: "secret"})

      stderr =
        capture_io(:stderr, fn ->
          assert 1 == MCP.login(%{name: "docs", client_id: nil, client_secret: "secret"})
        end)

      assert stderr =~ "--client-secret requires --client-id"
    end
  end
end
