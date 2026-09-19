defmodule Tackle.Web.GitHubTest do
  # Mutates the global :github_host configuration.
  use ExUnit.Case, async: false

  alias Tackle.Web.GitHub

  describe "parse/1" do
    test "accepts a full pull request URL" do
      assert GitHub.parse("https://github.com/elixir-lang/elixir/pull/12345") ==
               {:ok, {"elixir-lang", "elixir", 12345}}
    end

    test "accepts the short form" do
      assert GitHub.parse("elixir-lang/elixir#42") == {:ok, {"elixir-lang", "elixir", 42}}
    end

    test "accepts a path without the host" do
      assert GitHub.parse("elixir-lang/elixir/pull/42") == {:ok, {"elixir-lang", "elixir", 42}}
    end

    test "accepts an http URL" do
      assert GitHub.parse("http://github.com/owner/repo/pull/7") == {:ok, {"owner", "repo", 7}}
    end

    test "ignores surrounding whitespace" do
      assert GitHub.parse("  owner/repo#7  ") == {:ok, {"owner", "repo", 7}}
    end

    test "does not mistake the repository name for the number" do
      assert GitHub.parse("owner/repo/pull/7") == {:ok, {"owner", "repo", 7}}
    end

    test "rejects input that is not a pull request" do
      assert {:error, message} = GitHub.parse("elixir")
      assert message =~ "owner/repo"

      assert {:error, _message} = GitHub.parse("elixir-lang/elixir")
      assert {:error, _message} = GitHub.parse("https://github.com/owner/repo/issues/5")
      assert {:error, _message} = GitHub.parse("")
    end
  end

  describe "clone URLs" do
    test "default to github.com" do
      assert GitHub.clone_url("owner", "repo") == "https://github.com/owner/repo.git"
    end

    test "follow a configured host" do
      put_host("https://github.example.com/", fn ->
        assert GitHub.clone_url("owner", "repo") ==
                 "https://github.example.com/owner/repo.git"
      end)
    end

    test "ignore a blank configured host" do
      put_host("", fn ->
        assert GitHub.clone_url("owner", "repo") == "https://github.com/owner/repo.git"
      end)
    end
  end

  describe "from_api/3" do
    test "maps the fields the review UI needs" do
      pull = GitHub.from_api(payload(), "elixir-lang", "elixir")

      assert pull.title == "Support for XYZ"
      assert pull.number == 12345
      assert pull.author == "contributor"
      assert pull.state == "open"
      assert pull.base_ref == "main"
      assert pull.head_ref == "feature"
      assert pull.head_sha == "headsha"
      assert pull.base_sha == "basesha"
      assert pull.additions == 12
      assert pull.deletions == 3
      assert pull.changed_files == 2
    end

    test "prefers the base repository's clone URL, because pull request refs live there" do
      pull = GitHub.from_api(payload(), "elixir-lang", "elixir")
      assert pull.clone_url == "https://github.com/elixir-lang/elixir.git"
    end

    test "falls back to the configured host when the payload omits the repository" do
      payload = payload() |> Map.put("base", %{"ref" => "main", "sha" => "basesha"})

      assert GitHub.from_api(payload, "elixir-lang", "elixir").clone_url ==
               "https://github.com/elixir-lang/elixir.git"
    end

    test "tolerates absent optional fields" do
      pull = GitHub.from_api(%{"number" => 1}, "owner", "repo")

      assert pull.body == ""
      assert pull.state == "unknown"
      assert pull.author == nil
      assert pull.draft == false
      assert pull.additions == 0
      assert pull.changed_files == 0
    end

    test "reports drafts" do
      assert GitHub.from_api(payload() |> Map.put("draft", true), "o", "r").draft == true
    end
  end

  describe "pull/3" do
    test "reads a pull request over HTTP" do
      Tackle.Web.GitHubStub.start(Tackle.Web.GitHubStub.pull_payload())

      assert {:ok, pull} = GitHub.pull("acme", "widgets", 7)

      assert pull.title == "Teach the widget to spin"
      assert pull.number == 7
      assert pull.author == "contributor"
      assert pull.base_ref == "main"
      assert pull.head_ref == "feature"
      assert pull.clone_url == "https://github.com/acme/widgets.git"
    end

    test "reports a pull request GitHub does not have" do
      Tackle.Web.GitHubStub.start({404, ~s({"message": "Not Found"})})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "no such pull request"
    end

    test "reports a rejected token" do
      Tackle.Web.GitHubStub.start({401, ~s({"message": "Bad credentials"})})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "rejected the configured token"
    end

    test "reports a rate limit" do
      Tackle.Web.GitHubStub.start({403, ~s({"message": "API rate limit exceeded"})})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "rate limit"
    end

    test "reports any other refusal" do
      Tackle.Web.GitHubStub.start({500, ~s({"message": "boom"})})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "HTTP 500"
    end

    test "reports a body that is not JSON" do
      Tackle.Web.GitHubStub.start({200, "<html>a proxy got in the way</html>"})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "not valid JSON"
    end

    test "reports a body that is JSON but not a pull request" do
      Tackle.Web.GitHubStub.start({200, "[1, 2, 3]"})

      assert {:error, message} = GitHub.pull("acme", "widgets", 7)
      assert message =~ "unexpected response body"
    end

    test "reports GitHub being unreachable" do
      put_api_url("http://127.0.0.1:1", fn ->
        assert {:error, message} = GitHub.pull("acme", "widgets", 7)
        assert message =~ "Could not reach GitHub"
      end)
    end
  end

  defp payload do
    %{
      "number" => 12345,
      "title" => "Support for XYZ",
      "body" => "Adds XYZ.",
      "state" => "open",
      "draft" => false,
      "html_url" => "https://github.com/elixir-lang/elixir/pull/12345",
      "additions" => 12,
      "deletions" => 3,
      "changed_files" => 2,
      "user" => %{"login" => "contributor"},
      "base" => %{
        "ref" => "main",
        "sha" => "basesha",
        "repo" => %{"clone_url" => "https://github.com/elixir-lang/elixir.git"}
      },
      "head" => %{
        "ref" => "feature",
        "sha" => "headsha",
        "repo" => %{"clone_url" => "https://github.com/contributor/elixir.git"}
      }
    }
  end

  defp put_api_url(url, fun) do
    previous = Application.get_env(:tackle_web, :github_api_url)
    Application.put_env(:tackle_web, :github_api_url, url)

    try do
      fun.()
    after
      restore_api_url(previous)
    end
  end

  defp restore_api_url(nil), do: Application.delete_env(:tackle_web, :github_api_url)
  defp restore_api_url(value), do: Application.put_env(:tackle_web, :github_api_url, value)

  defp put_host(host, fun) do
    previous = Application.get_env(:tackle_web, :github_host)
    Application.put_env(:tackle_web, :github_host, host)

    try do
      fun.()
    after
      restore_host(previous)
    end
  end

  defp restore_host(nil), do: Application.delete_env(:tackle_web, :github_host)
  defp restore_host(value), do: Application.put_env(:tackle_web, :github_host, value)
end
