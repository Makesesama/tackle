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

  test "user_home prefers the option, then HOME of the environment, then the system" do
    assert Paths.user_home(user_home: "/home/a/../b") == "/home/b"
    assert Paths.user_home(user_home: nil, env: %{"HOME" => "/home/a"}) == nil
    assert Paths.user_home(env: %{"HOME" => "/home/a"}) == "/home/a"
    assert Paths.user_home(env: %{"USERPROFILE" => "/home/c"}) == "/home/c"
    assert Paths.user_home(env: %{"HOME" => ""}) == nil
    assert Paths.user_home(env: %{}) == nil
    assert Paths.user_home() == System.user_home() |> Path.expand()
    assert Paths.agents_dir(env: %{"HOME" => "/home/a"}) == {:ok, "/home/a/.agents"}
    assert Paths.agents_dir(user_home: nil) == {:error, :user_home_unavailable}
  end

  test "homes keeps the given homes and resolves the others from one environment" do
    env = %{"TACKLE_HOME" => "/srv/tackle", "HOME" => "/home/a"}
    assert Paths.homes(env: env) == [home: "/srv/tackle", user_home: "/home/a"]
    assert Paths.homes(env: env, home: nil) == [home: nil, user_home: "/home/a"]
    assert Paths.homes(env: env, home: "/x/../y", user_home: nil) == [home: "/y", user_home: nil]

    assert Paths.homes(env: %{}, user_home: "/home/b") == [
             home: "/home/b/.tackle",
             user_home: "/home/b"
           ]

    assert Paths.homes(env: %{}, user_home: nil) == [home: nil, user_home: nil]
  end
end
