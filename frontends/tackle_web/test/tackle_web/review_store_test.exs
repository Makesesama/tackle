defmodule Tackle.Web.ReviewStoreTest do
  # The store is a named process and the reviews root is global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Web.Paths
  alias Tackle.Web.Review
  alias Tackle.Web.ReviewStore

  setup do
    root = Tackle.Web.GitFixture.scratch_dir("reviews")
    previous = Application.get_env(:tackle_web, :reviews_root)
    Application.put_env(:tackle_web, :reviews_root, root)

    on_exit(fn ->
      restore(:reviews_root, previous)
      File.rm_rf(root)
    end)

    # A distinct pull request per test keeps the store's cache from leaking
    # between them.
    {:ok, root: root, identity: unique_identity()}
  end

  describe "comments" do
    test "stores a comment on the line it was written about", %{identity: {slug, review_id}} do
      assert {:ok, comment} =
               ReviewStore.add_comment(slug, review_id, %{
                 "path" => "lib/a.ex",
                 "side" => "new",
                 "line" => "42",
                 "body" => "  This looks wrong.  "
               })

      assert comment.path == "lib/a.ex"
      assert comment.side == :new
      assert comment.line == 42
      assert comment.body == "This looks wrong."
      assert comment.id =~ ~r/^[0-9a-f]{16}$/
      assert %DateTime{} = comment.inserted_at

      assert ReviewStore.get(slug, review_id).comments == [comment]
    end

    test "keeps comments in the order they were written", %{identity: {slug, review_id}} do
      for body <- ["first", "second", "third"] do
        ReviewStore.add_comment(slug, review_id, %{
          "path" => "lib/a.ex",
          "side" => "new",
          "line" => 1,
          "body" => body
        })
      end

      assert ReviewStore.get(slug, review_id).comments |> Enum.map(& &1.body) ==
               ["first", "second", "third"]
    end

    test "refuses a comment without a body", %{identity: {slug, review_id}} do
      assert {:error, message} =
               ReviewStore.add_comment(slug, review_id, %{
                 "path" => "lib/a.ex",
                 "side" => "new",
                 "line" => 1,
                 "body" => "   "
               })

      assert message =~ "Write something"
      assert ReviewStore.get(slug, review_id).comments == []
    end

    test "refuses a comment without a usable line", %{identity: {slug, review_id}} do
      for line <- ["", "abc", "0", "-3", nil] do
        assert {:error, message} =
                 ReviewStore.add_comment(slug, review_id, %{
                   "path" => "lib/a.ex",
                   "side" => "new",
                   "line" => line,
                   "body" => "x"
                 })

        assert message =~ "line number"
      end
    end

    test "refuses a comment without a side", %{identity: {slug, review_id}} do
      assert {:error, message} =
               ReviewStore.add_comment(slug, review_id, %{
                 "path" => "lib/a.ex",
                 "line" => 1,
                 "body" => "x"
               })

      assert message =~ "new or the old side"
    end

    test "refuses a comment without a file", %{identity: {slug, review_id}} do
      assert {:error, message} =
               ReviewStore.add_comment(slug, review_id, %{
                 "path" => "",
                 "side" => "new",
                 "line" => 1,
                 "body" => "x"
               })

      assert message =~ "needs a file"
    end

    test "removes a comment by id and ignores unknown ids", %{
      identity: {slug, review_id}
    } do
      {:ok, comment} = add_comment(slug, review_id, "remove me")

      assert ReviewStore.delete_comment(slug, review_id, comment.id) == :ok
      assert ReviewStore.get(slug, review_id).comments == []

      assert ReviewStore.delete_comment(slug, review_id, "not-an-id") == :ok
    end

    test "keeps comments on different files apart", %{identity: {slug, review_id}} do
      add_comment(slug, review_id, "on a", %{"path" => "lib/a.ex"})
      add_comment(slug, review_id, "on b", %{"path" => "lib/b.ex"})

      review = ReviewStore.get(slug, review_id)

      assert Review.comments_by_line(review, "lib/a.ex") |> map_size() == 1
      assert Review.comments_by_line(review, "lib/b.ex") |> map_size() == 1
      assert Review.comments_by_line(review, "lib/c.ex") == %{}
    end
  end

  describe "viewed markers" do
    test "marking a file as seen is idempotent", %{identity: {slug, review_id}} do
      assert ReviewStore.set_viewed(slug, review_id, "lib/a.ex", true) == :ok
      assert ReviewStore.set_viewed(slug, review_id, "lib/a.ex", true) == :ok

      assert ReviewStore.get(slug, review_id).viewed == MapSet.new(["lib/a.ex"])
    end

    test "a file can be marked unseen again", %{identity: {slug, review_id}} do
      ReviewStore.set_viewed(slug, review_id, "lib/a.ex", true)
      ReviewStore.set_viewed(slug, review_id, "lib/a.ex", false)

      assert ReviewStore.get(slug, review_id).viewed == MapSet.new()
    end

    test "toggling flips the marker and reports the new value", %{
      identity: {slug, review_id}
    } do
      assert ReviewStore.toggle_viewed(slug, review_id, "lib/a.ex") == true
      assert ReviewStore.get(slug, review_id).viewed == MapSet.new(["lib/a.ex"])

      assert ReviewStore.toggle_viewed(slug, review_id, "lib/a.ex") == false
      assert ReviewStore.get(slug, review_id).viewed == MapSet.new()
    end

    test "an unseen file is not viewed", %{identity: {slug, review_id}} do
      assert ReviewStore.get(slug, review_id).viewed == MapSet.new()
    end
  end

  describe "persistence" do
    test "writes comments as JSON under the reviews root", %{
      root: root,
      identity: {slug, review_id}
    } do
      {:ok, comment} = add_comment(slug, review_id, "persist me")

      path = Path.join(root, Review.file_name(slug, review_id))
      assert {:ok, contents} = File.read(path)

      assert %{"comments" => [stored]} = JSON.decode!(contents)
      assert stored["id"] == comment.id
      assert stored["body"] == "persist me"
      assert stored["side"] == "new"
      assert stored["line"] == 3
    end

    test "writes viewed markers as JSON", %{root: root, identity: {slug, review_id}} do
      ReviewStore.set_viewed(slug, review_id, "lib/a.ex", true)

      contents = root |> Path.join(Review.file_name(slug, review_id)) |> File.read!()

      assert %{"viewed" => ["lib/a.ex"]} = JSON.decode!(contents)
    end

    test "reads state an earlier run left behind", %{root: root} do
      {slug, review_id} = unique_identity()
      Paths.ensure_dir!(root)

      File.write!(
        Path.join(root, Review.file_name(slug, review_id)),
        JSON.encode!(%{
          "version" => 1,
          "viewed" => ["lib/a.ex"],
          "comments" => [
            %{
              "id" => "from-disk",
              "path" => "lib/a.ex",
              "side" => "old",
              "line" => 12,
              "body" => "written by an earlier run",
              "author" => "someone",
              "inserted_at" => "2024-01-01T00:00:00Z"
            }
          ]
        })
      )

      review = ReviewStore.get(slug, review_id)

      assert review.viewed == MapSet.new(["lib/a.ex"])
      assert [comment] = review.comments
      assert comment.id == "from-disk"
      assert comment.body == "written by an earlier run"
      assert comment.side == :old
      assert comment.inserted_at == ~U[2024-01-01 00:00:00Z]
    end

    test "treats unreadable state as an empty review instead of failing", %{root: root} do
      {slug, review_id} = unique_identity()
      Paths.ensure_dir!(root)
      File.write!(Path.join(root, Review.file_name(slug, review_id)), "{ not json")

      assert ReviewStore.get(slug, review_id) == Review.new()
    end
  end

  describe "notifications" do
    test "announces a change to subscribers of that review", %{
      identity: {slug, review_id}
    } do
      assert ReviewStore.subscribe(slug, review_id) == :ok
      add_comment(slug, review_id, "hello")

      assert_receive {:review_updated, _file}, 1_000
    end

    test "does not announce a rejected comment", %{identity: {slug, review_id}} do
      ReviewStore.subscribe(slug, review_id)

      {:error, _message} =
        ReviewStore.add_comment(slug, review_id, %{
          "path" => "lib/a.ex",
          "side" => "new",
          "line" => 1,
          "body" => ""
        })

      refute_receive {:review_updated, _file}, 100
    end

    test "does not announce another review's changes", %{
      identity: {slug, review_id}
    } do
      {other_slug, other_review_id} = unique_identity()
      ReviewStore.subscribe(other_slug, other_review_id)

      add_comment(slug, review_id, "not for you")

      refute_receive {:review_updated, _file}, 100
    end
  end

  defp add_comment(slug, review_id, body, overrides \\ %{}) do
    ReviewStore.add_comment(
      slug,
      review_id,
      Map.merge(%{"path" => "lib/a.ex", "side" => "new", "line" => 3, "body" => body}, overrides)
    )
  end

  # A distinct project and review per test keeps the store's cache from leaking
  # between them.
  defp unique_identity do
    {"github-acme-widgets-#{System.unique_integer([:positive])}",
     "pr-#{System.unique_integer([:positive])}"}
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
