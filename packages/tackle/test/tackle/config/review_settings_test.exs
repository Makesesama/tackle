defmodule Tackle.Config.ReviewSettingsTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
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

  describe "the review option of Tackle.Config.new/1" do
    test "puts the settings in the session context" do
      assert {:ok, config} =
               Config.new(
                 providers: [Adapter],
                 model: "test/default",
                 review: [thinking: [verifier: "low"]]
               )

      assert config.context.review_settings == %Settings{thinking: %{verifier: "low"}}
    end

    test "keeps settings the host already put in the context" do
      host = %Settings{thinking: %{detector: "minimal"}}

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
