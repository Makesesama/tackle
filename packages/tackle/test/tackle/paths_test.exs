defmodule Tackle.PathsTest do
  use ExUnit.Case, async: true

  import Tackle.Test.Runtime, only: [tmp_home: 0]

  alias Tackle.Paths
  alias Tackle.Session.Storage

  doctest Paths

  test "project keys are expanded, escaped path encodings enclosed in dashes" do
    assert Paths.project_key("/home/dev/projects/example") == "--home-dev-projects-example--"
    refute Paths.project_key("/tmp/a-b") == Paths.project_key("/tmp/a/b")
    assert Paths.project_key("/tmp/a/../b/") == Paths.project_key("/tmp/b")
    refute String.contains?(Paths.project_key("/tmp/a/b"), "/")
  end

  test "session storage keys project directories with the shared encoding" do
    home = tmp_home()

    for cwd <- ["/home/dev/projects/example", "/tmp/a-b", "/tmp/-2D-", "/"] do
      {:ok, dir} = Storage.session_dir("session-1", home: home, cwd: cwd)
      assert dir == Path.join([home, "sessions", Paths.project_key(cwd), "session-1"])
    end
  end
end
