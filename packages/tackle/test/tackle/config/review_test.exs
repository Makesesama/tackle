defmodule Tackle.Config.ReviewTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Config.Review

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["default"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  describe "new/2" do
    test "accepts every setting, with stage maps as maps or keyword lists" do
      assert {:ok, nil} = Review.new(nil, [Adapter])

      assert {:ok, %Review{thinking: %{}, models: %{}, max_steps: %{}}} =
               Review.new([], [Adapter])

      assert {:ok, review} =
               Review.new(
                 [
                   thinking: [detector: "low", verifier: "high"],
                   models: %{scorer: "test/default"},
                   profile: :quiet,
                   max_steps: [verifier: 6],
                   default_rules: ["injection", "injection", "unhandled-error"]
                 ],
                 [Adapter]
               )

      assert review == %Review{
               thinking: %{detector: "low", verifier: "high"},
               models: %{scorer: "test/default"},
               profile: :quiet,
               max_steps: %{verifier: 6},
               default_rules: ["injection", "unhandled-error"]
             }

      assert {:ok, ^review} = Review.new(review, [Adapter])
      assert {:ok, %Review{default_rules: []}} = Review.new([default_rules: []], [Adapter])
    end

    test "rejects unknown options, stages, levels, and values" do
      for opts <- [
            [thinking: [planner: "low"]],
            [thinking: [detector: "huge"]],
            [thinking: [detector: nil]],
            [thinking: "low"],
            [models: [detector: ""]],
            [profile: :loud],
            [max_steps: [scorer: 3]],
            [max_steps: [detector: 0]],
            [default_rules: "injection"],
            [default_rules: [:injection]]
          ] do
        assert {:error, {:invalid_option, :review, _}} = Review.new(opts, [Adapter]),
               inspect(opts)
      end

      assert {:error, {:invalid_option, :review, [:bogus]}} = Review.new([bogus: 1], [Adapter])
      assert {:error, {:invalid_option, :review, "low"}} = Review.new("low", [Adapter])
      assert {:error, {:invalid_option, :review, _}} = Review.new([:thinking], [Adapter])
    end

    test "resolves models against the providers and checks rule ids" do
      assert {:error, _reason} = Review.new([models: [verifier: "test/missing"]], [Adapter])
      assert {:error, _reason} = Review.new([models: [verifier: "other/x"]], [Adapter])

      assert {:error, {:unknown_default_rules, ["no-jason"]}} =
               Review.new([default_rules: ["injection", "no-jason"]], [Adapter])
    end
  end

  describe "Tackle.Config.new/1" do
    test "puts the settings in the session context" do
      assert {:ok, config} =
               Config.new(
                 providers: [Adapter],
                 model: "test/default",
                 review: [thinking: [verifier: "low"]]
               )

      assert config.review == %Review{thinking: %{verifier: "low"}}
      assert config.context.review_settings == config.review
    end

    test "keeps settings the host already put in the context" do
      host = %Review{thinking: %{detector: "minimal"}}

      assert {:ok, config} =
               Config.new(
                 providers: [Adapter],
                 model: "test/default",
                 context: %{review_settings: host},
                 review: [thinking: [verifier: "low"]]
               )

      assert config.context.review_settings == host
    end

    test "invalid settings fail configuration" do
      assert {:error, {:invalid_option, :review, _}} =
               Config.new(
                 providers: [Adapter],
                 model: "test/default",
                 review: [thinking: [verifier: "huge"]]
               )
    end
  end
end
