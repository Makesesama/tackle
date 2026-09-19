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
    test "stores a comment on the line it was written about", %{identity: {owner, name, number}} do
      assert {:ok, comment} =
               ReviewStore.add_comment(owner, name, number, %{
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

      assert ReviewStore.get(owner, name, number).comments == [comment]
    end

    test "keeps comments in the order they were written", %{identity: {owner, name, number}} do
      for body <- ["first", "second", "third"] do
        ReviewStore.add_comment(owner, name, number, %{
          "path" => "lib/a.ex",
          "side" => "new",
          "line" => 1,
          "body" => body
        })
      end

      assert ReviewStore.get(owner, name, number).comments |> Enum.map(& &1.body) ==
               ["first", "second", "third"]
    end

    test "refuses a comment without a body", %{identity: {owner, name, number}} do
      assert {:error, message} =
               ReviewStore.add_comment(owner, name, number, %{
                 "path" => "lib/a.ex",
                 "side" => "new",
                 "line" => 1,
                 "body" => "   "
               })

      assert message =~ "Write something"
      assert ReviewStore.get(owner, name, number).comments == []
    end

    test "refuses a comment without a usable line", %{identity: {owner, name, number}} do
      for line <- ["", "abc", "0", "-3", nil] do
        assert {:error, message} =
                 ReviewStore.add_comment(owner, name, number, %{
                   "path" => "lib/a.ex",
                   "side" => "new",
                   "line" => line,
                   "body" => "x"
                 })

        assert message =~ "line number"
      end
    end

    test "refuses a comment without a side", %{identity: {owner, name, number}} do
      assert {:error, message} =
               ReviewStore.add_comment(owner, name, number, %{
                 "path" => "lib/a.ex",
                 "line" => 1,
                 "body" => "x"
               })

      assert message =~ "new or the old side"
    end

    test "refuses a comment without a file", %{identity: {owner, name, number}} do
      assert {:error, message} =
               ReviewStore.add_comment(owner, name, number, %{
                 "path" => "",
                 "side" => "new",
                 "line" => 1,
                 "body" => "x"
               })

      assert message =~ "needs a file"
    end

    test "removes a comment by id and ignores unknown ids", %{
      identity: {owner, name, number}
    } do
      {:ok, comment} = add_comment(owner, name, number, "remove me")

      assert ReviewStore.delete_comment(owner, name, number, comment.id) == :ok
      assert ReviewStore.get(owner, name, number).comments == []

      assert ReviewStore.delete_comment(owner, name, number, "not-an-id") == :ok
    end

    test "keeps comments on different files apart", %{identity: {owner, name, number}} do
      add_comment(owner, name, number, "on a", %{"path" => "lib/a.ex"})
      add_comment(owner, name, number, "on b", %{"path" => "lib/b.ex"})

      review = ReviewStore.get(owner, name, number)

      assert Review.comments_by_line(review, "lib/a.ex") |> map_size() == 1
      assert Review.comments_by_line(review, "lib/b.ex") |> map_size() == 1
      assert Review.comments_by_line(review, "lib/c.ex") == %{}
    end
  end

  describe "viewed markers" do
    test "marking a file as seen is idempotent", %{identity: {owner, name, number}} do
      assert ReviewStore.set_viewed(owner, name, number, "lib/a.ex", true) == :ok
      assert ReviewStore.set_viewed(owner, name, number, "lib/a.ex", true) == :ok

      assert ReviewStore.get(owner, name, number).viewed == MapSet.new(["lib/a.ex"])
    end

    test "a file can be marked unseen again", %{identity: {owner, name, number}} do
      ReviewStore.set_viewed(owner, name, number, "lib/a.ex", true)
      ReviewStore.set_viewed(owner, name, number, "lib/a.ex", false)

      assert ReviewStore.get(owner, name, number).viewed == MapSet.new()
    end

    test "toggling flips the marker and reports the new value", %{
      identity: {owner, name, number}
    } do
      assert ReviewStore.toggle_viewed(owner, name, number, "lib/a.ex") == true
      assert ReviewStore.get(owner, name, number).viewed == MapSet.new(["lib/a.ex"])

      assert ReviewStore.toggle_viewed(owner, name, number, "lib/a.ex") == false
      assert ReviewStore.get(owner, name, number).viewed == MapSet.new()
    end

    test "an unseen file is not viewed", %{identity: {owner, name, number}} do
      assert ReviewStore.get(owner, name, number).viewed == MapSet.new()
    end
  end

  describe "persistence" do
    test "writes comments as JSON under the reviews root", %{
      root: root,
      identity: {owner, name, number}
    } do
      {:ok, comment} = add_comment(owner, name, number, "persist me")

      path = Path.join(root, Review.file_name(owner, name, number))
      assert {:ok, contents} = File.read(path)

      assert %{"comments" => [stored]} = JSON.decode!(contents)
      assert stored["id"] == comment.id
      assert stored["body"] == "persist me"
      assert stored["side"] == "new"
      assert stored["line"] == 3
    end

    test "writes viewed markers as JSON", %{root: root, identity: {owner, name, number}} do
      ReviewStore.set_viewed(owner, name, number, "lib/a.ex", true)

      contents = root |> Path.join(Review.file_name(owner, name, number)) |> File.read!()

      assert %{"viewed" => ["lib/a.ex"]} = JSON.decode!(contents)
    end

    test "reads state an earlier run left behind", %{root: root} do
      owner = unique_owner()
      number = 1
      Paths.ensure_dir!(root)

      File.write!(
        Path.join(root, Review.file_name(owner, "widgets", number)),
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

      review = ReviewStore.get(owner, "widgets", number)

      assert review.viewed == MapSet.new(["lib/a.ex"])
      assert [comment] = review.comments
      assert comment.id == "from-disk"
      assert comment.body == "written by an earlier run"
      assert comment.side == :old
      assert comment.inserted_at == ~U[2024-01-01 00:00:00Z]
    end

    test "treats unreadable state as an empty review instead of failing", %{root: root} do
      owner = unique_owner()
      Paths.ensure_dir!(root)
      File.write!(Path.join(root, Review.file_name(owner, "widgets", 1)), "{ not json")

      assert ReviewStore.get(owner, "widgets", 1) == Review.new()
    end
  end

  describe "notifications" do
    test "announces a change to subscribers of that pull request", %{
      identity: {owner, name, number}
    } do
      assert ReviewStore.subscribe(owner, name, number) == :ok
      add_comment(owner, name, number, "hello")

      assert_receive {:review_updated, _file}, 1_000
    end

    test "does not announce a rejected comment", %{identity: {owner, name, number}} do
      ReviewStore.subscribe(owner, name, number)

      {:error, _message} =
        ReviewStore.add_comment(owner, name, number, %{
          "path" => "lib/a.ex",
          "side" => "new",
          "line" => 1,
          "body" => ""
        })

      refute_receive {:review_updated, _file}, 100
    end

    test "does not announce another pull request's changes", %{
      identity: {owner, name, number}
    } do
      other = unique_identity()
      ReviewStore.subscribe(other |> elem(0), other |> elem(1), other |> elem(2))

      add_comment(owner, name, number, "not for you")

      refute_receive {:review_updated, _file}, 100
    end
  end

  defp add_comment(owner, name, number, body, overrides \\ %{}) do
    ReviewStore.add_comment(
      owner,
      name,
      number,
      Map.merge(%{"path" => "lib/a.ex", "side" => "new", "line" => 3, "body" => body}, overrides)
    )
  end

  defp unique_owner do
    "owner#{System.unique_integer([:positive])}"
  end

  defp unique_identity do
    number = System.unique_integer([:positive])
    {unique_owner(), "widgets", number}
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
