defmodule Tackle.Review.ScorerTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM
  alias Tackle.Review.{Finding, Scorer}

  defmodule Adapter do
    @moduledoc false
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "score"

    @impl true
    def models, do: ["fake"]

    @impl true
    def generate(schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:generate, schema, opts})
      Keyword.fetch!(opts, :answer)
    end
  end

  defmodule Fixed do
    @moduledoc false
    @behaviour Tackle.Review.Scorer

    @impl true
    def score(_items, %{answer: answer}), do: answer
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Tackle.Review.Scorer

    @impl true
    def score(_items, _context), do: raise("broken")
  end

  @unit %{id: "lib/a.ex#1", rendered: "File: lib/a.ex\n\n[+ 3]   map.key\n"}
  @other_unit %{id: "lib/b.ex#1", rendered: "File: lib/b.ex\n\n[+ 9]   File.read!(path)\n"}

  defp finding(overrides \\ %{}) do
    struct!(
      %Finding{
        title: "Guard against a missing key",
        category: :correctness,
        severity: :high,
        blocking: true,
        confidence: 0.7,
        location: %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 3},
        trigger: "a map without :key",
        body: "map.key raises.",
        verdict: :confirmed
      },
      overrides
    )
  end

  defp item(finding \\ finding(), unit \\ @unit), do: %{finding: finding, unit: unit, rule: nil}

  describe "score/3" do
    test "accepts confidences from 0 to 1, one per item" do
      assert {:ok, [1.0, +0.0], nil} =
               Scorer.score(Fixed, [item(), item()], %{answer: {:ok, [1, 0], nil}})
    end

    test "turns invalid answers and raises into errors" do
      assert {:error, {:invalid_confidence, 1.5}} =
               Scorer.score(Fixed, [item()], %{answer: {:ok, [1.5], nil}})

      assert {:error, {:invalid_confidence_count, 1, 2}} =
               Scorer.score(Fixed, [item(), item()], %{answer: {:ok, [0.5], nil}})

      assert {:error, {:invalid_scorer_result, :what}} =
               Scorer.score(Fixed, [item()], %{answer: :what})

      assert {:error, :down} = Scorer.score(Fixed, [item()], %{answer: {:error, :down}})
      assert {:error, {:scorer_crashed, "broken"}} = Scorer.score(Raising, [item()], %{})
    end
  end

  describe "Scorer.LLM" do
    setup do
      {:ok, selection} = LLM.select([Adapter], "score/fake")
      %{selection: selection}
    end

    defp context(selection, answer) do
      %{llm: selection, llm_opts: [test_pid: self(), answer: answer]}
    end

    defp answer(scores),
      do: {:ok, %{data: %{"scores" => scores}, usage: %{input_tokens: 7}, model: "fake"}}

    test "scores a batch in one structured call, showing each unit once", %{
      selection: selection
    } do
      items = [
        item(),
        item(
          finding(%{title: "Handle a nil map", location: %{finding().location | start_line: 3}})
        ),
        item(
          finding(%{
            title: "Handle a read error",
            location: %{path: "lib/b.ex", side: :new, start_line: 9, end_line: 9}
          }),
          @other_unit
        )
      ]

      scores = [
        %{"id" => "C3", "confidence" => 0.5},
        %{"id" => "C1", "confidence" => 0.25},
        %{"id" => "C2", "confidence" => 1}
      ]

      assert {:ok, [0.25, 1.0, 0.5], usage} =
               Scorer.LLM.score(items, context(selection, answer(scores)))

      assert usage.input_tokens == 7

      assert_received {:generate, schema, opts}
      assert schema == Scorer.LLM.schema()
      assert opts[:tools] == []
      assert [%{role: :user, content: prompt}] = opts[:messages]
      assert prompt =~ "Rate 3 comments"
      assert prompt =~ "Comments developers do not want"
      assert prompt =~ ~s|<comment id="C1" unit="lib/a.ex#1">\nlib/a.ex:3-3 (new side)|
      assert prompt =~ ~s(<comment id="C3" unit="lib/b.ex#1">)
      assert prompt =~ "verdict: confirmed"
      assert length(String.split(prompt, ~s(<unit id="lib/a.ex#1">))) == 2
      assert prompt =~ "[+ 9]   File.read!(path)"
    end

    test "rejects answers that do not score every comment exactly once", %{
      selection: selection
    } do
      items = [item(), item()]

      for scores <- [
            [%{"id" => "C1", "confidence" => 0.5}],
            [%{"id" => "C1", "confidence" => 0.5}, %{"id" => "C1", "confidence" => 0.2}],
            [%{"id" => "C1", "confidence" => 0.5}, %{"id" => "C2", "confidence" => "high"}],
            [
              %{"id" => "C1", "confidence" => 0.5},
              %{"id" => "C2", "confidence" => 0.5},
              %{"id" => "C3", "confidence" => 0.5}
            ]
          ] do
        assert {:error, {:invalid_score_response, %{"scores" => ^scores}}} =
                 Scorer.LLM.score(items, context(selection, answer(scores)))
      end

      bad = {:ok, %{data: %{"confidence" => 0.5}, usage: nil, model: "fake"}}

      assert {:error, {:invalid_score_response, %{"confidence" => 0.5}}} =
               Scorer.LLM.score(items, context(selection, bad))
    end

    test "passes errors on", %{selection: selection} do
      assert {:error, :rate_limited} =
               Scorer.LLM.score([item()], context(selection, {:error, :rate_limited}))

      assert {:error, :missing_llm} = Scorer.LLM.score([item()], %{})
    end
  end
end
