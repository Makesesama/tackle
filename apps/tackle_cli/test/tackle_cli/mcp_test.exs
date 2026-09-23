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
end
