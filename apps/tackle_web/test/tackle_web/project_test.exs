defmodule Tackle.Web.ProjectTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Project
  alias Tackle.Web.Project.Source.GitHub
  alias Tackle.Web.Project.Source.Local

  describe "slug/2" do
    test "names the kind and the locator, in a URL-safe form" do
      assert Project.slug(:github, "joshrotenberg/git_wrapper_ex") =~
               ~r/\Agithub-joshrotenberg-git-wrapper-ex-[0-9a-f]{6}\z/
    end

    test "is stable for the same kind and locator" do
      assert Project.slug(:local, "/srv/code") == Project.slug(:local, "/srv/code")
    end

    test "keeps locators that slugify the same apart" do
      # Slugifying alone folds these onto "local-srv-a-b".
      refute Project.slug(:local, "/srv/a-b") == Project.slug(:local, "/srv/a/b")
    end

    test "keeps the same locator on two kinds apart" do
      refute Project.slug(:local, "acme/widgets") == Project.slug(:github, "acme/widgets")
    end
  end

  describe "kind/1" do
    test "accepts an atom or the string a form sends" do
      assert Project.kind(:local) == {:ok, :local}
      assert Project.kind("github") == {:ok, :github}
    end

    test "rejects anything else without inventing an atom" do
      assert Project.kind("nope") == :error
      assert Project.kind("") == :error
      assert Project.kind(nil) == :error
      assert Project.kind(:nope) == :error
    end
  end

  describe "ref review ids" do
    test "round-trip two refs" do
      id = Project.ref_review_id("main", "feature/one")

      assert Project.parse_ref_review_id(id) == {:ok, {"main", "feature/one"}}
    end

    test "escape a slash so the id stays one path segment and one file name" do
      assert Project.ref_review_id("release/1.2", "main") == "release~/1.2..main"
    end

    test "leave a revision expression round-trippable" do
      id = Project.ref_review_id("HEAD~1", "HEAD")

      assert id == "HEAD~~1..HEAD"
      assert Project.parse_ref_review_id(id) == {:ok, {"HEAD~1", "HEAD"}}
    end

    test "reject anything that is not two refs" do
      assert Project.parse_ref_review_id("pr-7") == :error
      assert Project.parse_ref_review_id("main..") == :error
      assert Project.parse_ref_review_id("a..b..c") == :error
    end
  end

  test "labels and sources" do
    assert Project.label(:local) == "Local"
    assert Project.label(:github) == "GitHub"
    assert Project.kinds() == [:local, :github]
    assert Project.source(:local) == Local
    assert Project.source(:github) == GitHub
    assert Project.source(%Project{slug: "s", kind: :github, locator: "a/b"}) == GitHub
  end
end
