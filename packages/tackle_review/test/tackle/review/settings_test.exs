defmodule Tackle.Review.SettingsTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Settings

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
      assert {:ok, nil} = Settings.new(nil, [Adapter])

      assert {:ok, %Settings{thinking: %{}, models: %{}, max_steps: %{}}} =
               Settings.new([], [Adapter])

      assert {:ok, review} =
               Settings.new(
                 [
                   thinking: [detector: "low", verifier: "high"],
                   models: %{scorer: "test/default"},
                   profile: :quiet,
                   max_steps: [verifier: 6],
                   default_rules: ["injection", "injection", "unhandled-error"]
                 ],
                 [Adapter]
               )

      assert review == %Settings{
               thinking: %{detector: "low", verifier: "high"},
               models: %{scorer: "test/default"},
               profile: :quiet,
               max_steps: %{verifier: 6},
               default_rules: ["injection", "unhandled-error"]
             }

      assert {:ok, ^review} = Settings.new(review, [Adapter])
      assert {:ok, %Settings{default_rules: []}} = Settings.new([default_rules: []], [Adapter])
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
        assert {:error, {:invalid_option, :review, _}} = Settings.new(opts, [Adapter]),
               inspect(opts)
      end

      assert {:error, {:invalid_option, :review, [:bogus]}} = Settings.new([bogus: 1], [Adapter])
      assert {:error, {:invalid_option, :review, "low"}} = Settings.new("low", [Adapter])
      assert {:error, {:invalid_option, :review, _}} = Settings.new([:thinking], [Adapter])
    end

    test "resolves models against the providers and checks rule ids" do
      assert {:error, _reason} = Settings.new([models: [verifier: "test/missing"]], [Adapter])
      assert {:error, _reason} = Settings.new([models: [verifier: "other/x"]], [Adapter])

      assert {:error, {:unknown_default_rules, ["no-jason"]}} =
               Settings.new([default_rules: ["injection", "no-jason"]], [Adapter])
    end
  end

  describe "from_json/1" do
    test "maps the JSON object to options without creating atoms" do
      assert {:ok, opts} =
               Settings.from_json(%{
                 "profile" => "quiet",
                 "models" => %{"verifier" => "test/default"},
                 "thinking" => %{"detector" => "low"},
                 "max_steps" => %{"verifier" => 6},
                 "default_rules" => ["injection"]
               })

      assert Enum.sort(opts) == [
               default_rules: ["injection"],
               max_steps: %{verifier: 6},
               models: %{verifier: "test/default"},
               profile: :quiet,
               thinking: %{detector: "low"}
             ]

      assert {:ok, [profile: :default]} =
               Settings.from_json(%{"profile" => "default", "models" => nil})

      assert {:ok, settings} = Settings.new(opts, [Adapter])
      assert settings.profile == :quiet
    end

    test "rejects unknown fields and values of the wrong shape" do
      for review <- [
            %{"profiles" => "quiet"},
            %{"profile" => "loud"},
            %{"thinking" => %{"writer" => "low"}},
            %{"thinking" => %{"detector" => "huge"}},
            %{"max_steps" => %{"detector" => 0}},
            %{"models" => %{"detector" => ""}},
            %{"default_rules" => "injection"},
            "quiet"
          ] do
        assert Settings.from_json(review) == :error, inspect(review)
      end

      # The shape is right; new/2 rejects a scorer step limit.
      assert {:ok, opts} = Settings.from_json(%{"max_steps" => %{"scorer" => 2}})
      assert {:error, {:invalid_option, :review, _}} = Settings.new(opts, [Adapter])
    end
  end
end
