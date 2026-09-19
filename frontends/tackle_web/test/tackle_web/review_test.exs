defmodule Tackle.Web.ReviewTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Review

  describe "file_name/3" do
    test "combines the pull request identity" do
      assert Review.file_name("elixir-lang", "elixir", 42) == "elixir-lang__elixir__42.json"
    end

    test "keeps hyphens, which GitHub logins contain" do
      assert Review.file_name("a-b", "c-d", 1) == "a-b__c-d__1.json"
    end
  end

  describe "JSON round trip" do
    test "preserves comments and viewed markers" do
      review = %{
        Review.new()
        | viewed: MapSet.new(["lib/a.ex", "lib/b.ex"]),
          comments: [comment(), comment(%{id: "second", path: "lib/b.ex", line: 9})]
      }

      restored =
        review |> Review.to_json() |> JSON.encode!() |> JSON.decode!() |> Review.from_json()

      assert restored.viewed == MapSet.new(["lib/a.ex", "lib/b.ex"])
      assert length(restored.comments) == 2

      [first, second] = restored.comments
      assert first.id == "abc123"
      assert first.path == "lib/a.ex"
      assert first.side == :new
      assert first.line == 42
      assert first.body == "This looks wrong."
      assert first.author == "reviewer"
      assert second.id == "second"
    end

    test "keeps the timestamp to the second" do
      restored = review() |> Review.to_json() |> Review.from_json()
      assert [comment] = restored.comments
      assert DateTime.compare(comment.inserted_at, DateTime.utc_now()) == :lt
    end

    test "serializes the side as a string" do
      assert [%{"side" => "new", "inserted_at" => timestamp}] =
               Review.to_json(review())["comments"]

      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(timestamp)
    end
  end

  describe "from_json/1" do
    test "starts fresh when the stored state is unusable" do
      assert Review.from_json(%{}) == Review.new()
      assert Review.from_json(nil) == Review.new()
      assert Review.from_json("nonsense") == Review.new()
      assert Review.from_json(%{"comments" => "not a list"}) == Review.new()
    end

    test "skips individual comments it cannot read rather than dropping the review" do
      stored = %{
        "viewed" => ["lib/a.ex", 7, nil],
        "comments" => [
          %{"id" => "keep", "path" => "lib/a.ex", "side" => "new", "line" => 1, "body" => "ok"},
          %{"id" => "no side", "path" => "lib/a.ex", "line" => 1, "body" => "x"},
          %{
            "id" => "bad side",
            "path" => "lib/a.ex",
            "side" => "middle",
            "line" => 1,
            "body" => "x"
          },
          "garbage",
          %{"path" => "missing id", "side" => "new", "line" => 1, "body" => "x"}
        ]
      }

      review = Review.from_json(stored)

      assert review.viewed == MapSet.new(["lib/a.ex"])
      assert [%{id: "keep"}] = review.comments
    end

    test "defaults a missing author and timestamp" do
      stored = %{
        "comments" => [
          %{"id" => "a", "path" => "lib/a.ex", "side" => "old", "line" => 3, "body" => "x"}
        ]
      }

      assert [%{author: "reviewer", side: :old, inserted_at: %DateTime{}}] =
               Review.from_json(stored).comments
    end
  end

  describe "comments_by_line/2" do
    test "groups only the comments anchored to the requested file" do
      review = %{
        Review.new()
        | comments: [
            comment(%{id: "1", path: "lib/a.ex", line: 4}),
            comment(%{id: "2", path: "lib/a.ex", line: 4}),
            comment(%{id: "3", path: "lib/a.ex", line: 5, side: :old}),
            comment(%{id: "4", path: "lib/b.ex", line: 4})
          ]
      }

      grouped = Review.comments_by_line(review, "lib/a.ex")

      assert grouped |> Map.keys() |> Enum.sort() == [{:new, 4}, {:old, 5}]
      assert grouped[{:new, 4}] |> Enum.map(& &1.id) == ["1", "2"]
    end

    test "returns nothing for a file with no comments" do
      assert Review.comments_by_line(Review.new(), "lib/a.ex") == %{}
    end
  end

  defp review do
    %{Review.new() | comments: [comment()]}
  end

  defp comment(overrides \\ %{}) do
    Map.merge(
      %{
        id: "abc123",
        path: "lib/a.ex",
        side: :new,
        line: 42,
        body: "This looks wrong.",
        author: "reviewer",
        inserted_at: DateTime.utc_now()
      },
      overrides
    )
  end
end
