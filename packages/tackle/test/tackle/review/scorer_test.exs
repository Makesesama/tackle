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
    def score(_finding, %{answer: answer}), do: answer
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Tackle.Review.Scorer

    @impl true
    def score(_finding, _context), do: raise("broken")
  end

  @unit %{id: "lib/a.ex#1", rendered: "File: lib/a.ex\n\n[+ 3]   map.key\n"}

  defp finding do
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
    }
  end

  describe "score/3" do
    test "accepts confidences from 0 to 1" do
      assert {:ok, 1.0, nil} = Scorer.score(Fixed, finding(), %{answer: {:ok, 1, nil}})
      assert {:ok, +0.0, nil} = Scorer.score(Fixed, finding(), %{answer: {:ok, 0, nil}})
    end

    test "turns invalid answers and raises into errors" do
      assert {:error, {:invalid_confidence, 1.5}} =
               Scorer.score(Fixed, finding(), %{answer: {:ok, 1.5, nil}})

      assert {:error, {:invalid_scorer_result, :what}} =
               Scorer.score(Fixed, finding(), %{answer: :what})

      assert {:error, :down} = Scorer.score(Fixed, finding(), %{answer: {:error, :down}})
      assert {:error, {:scorer_crashed, "broken"}} = Scorer.score(Raising, finding(), %{})
    end
  end

  describe "Scorer.LLM" do
    setup do
      {:ok, selection} = LLM.select([Adapter], "score/fake")
      %{selection: selection}
    end

    defp context(selection, answer) do
      %{unit: @unit, rule: nil, llm: selection, llm_opts: [test_pid: self(), answer: answer]}
    end

    test "makes one structured call and returns its confidence and usage", %{selection: selection} do
      answer = {:ok, %{data: %{"confidence" => 0.25}, usage: %{input_tokens: 7}, model: "fake"}}

      assert {:ok, 0.25, usage} = Scorer.LLM.score(finding(), context(selection, answer))
      assert usage.input_tokens == 7

      assert_received {:generate, schema, opts}
      assert schema == Scorer.LLM.schema()
      assert opts[:tools] == []
      assert [%{role: :user, content: prompt}] = opts[:messages]
      assert prompt =~ "Comments developers do not want"
      assert prompt =~ "lib/a.ex:3-3 (new side)"
      assert prompt =~ "verdict: confirmed"
      assert prompt =~ "[+ 3]   map.key"
    end

    test "rejects malformed answers and passes errors on", %{selection: selection} do
      bad = {:ok, %{data: %{"confidence" => "high"}, usage: nil, model: "fake"}}

      assert {:error, {:invalid_score_response, %{"confidence" => "high"}}} =
               Scorer.LLM.score(finding(), context(selection, bad))

      assert {:error, :rate_limited} =
               Scorer.LLM.score(finding(), context(selection, {:error, :rate_limited}))

      assert {:error, :missing_llm} = Scorer.LLM.score(finding(), %{unit: @unit, rule: nil})
    end
  end
end
