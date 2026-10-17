defmodule Tackle.Web.ReviewProgressTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Finding
  alias Tackle.Web.{ReviewProgress, Updates}

  defp finding(fingerprint, title) do
    %Finding{
      fingerprint: fingerprint,
      title: title,
      category: :security,
      severity: :high,
      blocking: true,
      confidence: 0.9,
      trigger: "always",
      body: "Body.",
      location: %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 5}
    }
  end

  defp fold(events, progress \\ ReviewProgress.new()),
    do: Enum.reduce(events, progress, &ReviewProgress.apply(&2, &1))

  describe "apply/2" do
    test "folds the job's phases and the review's events" do
      progress =
        fold([
          {:phase, :jail},
          {:phase, :loading},
          {:started, %{units: 3}},
          {:unit, "lib/a.ex#0", :started},
          {:unit, "lib/b.ex#0", :started},
          {:unit, "lib/a.ex#0", :done},
          {:unit, "lib/b.ex#0", {:failed, :timeout}},
          {:candidate, finding("f1", "Injection")}
        ])

      assert progress.phase == :reviewing
      assert progress.units == [{"lib/b.ex#0", :failed}, {"lib/a.ex#0", :done}]

      assert [
               %{
                 fingerprint: "f1",
                 title: "Injection",
                 severity: :high,
                 path: "lib/a.ex",
                 start_line: 3,
                 end_line: 5,
                 verdict: nil
               }
             ] = progress.candidates

      assert %{total: 3, done: 1, failed: 1, running: 0, candidates: 1, verifying: 1} =
               ReviewProgress.counts(progress)

      assert ReviewProgress.stage(progress) == :detecting
      assert ReviewProgress.describe(progress) == "Reviewing: 2 of 3 parts done"

      progress = fold([{:unit, "lib/c.ex#0", :done}], progress)
      assert ReviewProgress.stage(progress) == :verifying
      assert ReviewProgress.describe(progress) == "Verifying findings: 0 of 1 checked"

      progress = fold([{:verdict, "f1", :confirmed}, {:verdict, "f2", :rejected}], progress)

      assert [%{fingerprint: "f2", title: nil, verdict: :rejected}, %{verdict: :confirmed}] =
               progress.candidates

      assert ReviewProgress.stage(progress) == :ranking
      assert ReviewProgress.describe(progress) == "Ranking the findings"
      assert ReviewProgress.describe(fold([{:phase, :posting}], progress)) =~ "Posting"
    end

    test "returns the same projection for events it does not show" do
      progress = ReviewProgress.new()

      for event <- [{:done, %{}}, {:error, :boom}, {:phase, :unknown}, {:verdict, "f", :odd}, :x] do
        assert ReviewProgress.apply(progress, event) === progress
      end
    end

    test "keeps the latest 200 candidates and counts the rest" do
      events = for n <- 1..205, do: {:candidate, finding("f#{n}", "Finding #{n}")}
      progress = fold(events)

      assert Enum.count(progress.candidates) == 200
      assert progress.omitted == 5
      assert hd(progress.candidates).fingerprint == "f205"
      assert List.last(progress.candidates).fingerprint == "f6"
      assert ReviewProgress.counts(progress).candidates == 205

      # A verdict for a candidate no longer kept is not counted again.
      assert ReviewProgress.apply(progress, {:verdict, "f1", :confirmed}) === progress
    end
  end

  describe "track/3 and report/2" do
    test "the tracking process reports; pages get each change and the end" do
      id = Ecto.UUID.generate()
      :ok = Updates.subscribe(Updates.review(id))
      assert ReviewProgress.current(id) == nil

      result =
        ReviewProgress.track(id, :checkout, fn ->
          assert_received {ReviewProgress, ^id, v1, %ReviewProgress{phase: :checkout}}
          assert %ReviewProgress{phase: :checkout, version: ^v1} = ReviewProgress.current(id)

          assert :ok = ReviewProgress.report(id, {:phase, :jail})
          assert_received {ReviewProgress, ^id, v2, %ReviewProgress{phase: :jail}}
          assert v2 > v1

          # Unchanged: nothing is sent.
          assert :ok = ReviewProgress.report(id, {:done, %{}})
          refute_received {ReviewProgress, ^id, _version, _progress}

          # Nested tracking of the same request just runs.
          assert :nested = ReviewProgress.track(id, :posting, fn -> :nested end)
          assert %ReviewProgress{phase: :jail} = ReviewProgress.current(id)
          :result
        end)

      assert result == :result
      assert_received {ReviewProgress, ^id, _version, nil}
      assert ReviewProgress.current(id) == nil
    end

    test "the progress goes away when the job raises" do
      id = Ecto.UUID.generate()

      assert_raise RuntimeError, fn ->
        ReviewProgress.track(id, :checkout, fn -> raise "boom" end)
      end

      assert ReviewProgress.current(id) == nil
    end

    test "other processes cannot report, and reporting never raises" do
      id = Ecto.UUID.generate()
      test = self()

      ReviewProgress.track(id, :checkout, fn ->
        Task.async(fn -> send(test, {:other, ReviewProgress.report(id, {:phase, :jail})}) end)
        |> Task.await()

        assert_received {:other, :ok}
        assert %ReviewProgress{phase: :checkout} = ReviewProgress.current(id)
      end)

      assert :ok = ReviewProgress.report(id, {:phase, :jail})
      assert :ok = ReviewProgress.report(Ecto.UUID.generate(), :not_an_event)
    end
  end
end
