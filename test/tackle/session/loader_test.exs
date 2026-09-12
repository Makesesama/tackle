defmodule Tackle.Session.LoaderTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Session.Loader
  alias Tackle.Session.Projection

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "loader-test"

    @impl true
    def models, do: ["model"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  test "restores the persisted session id without consuming a generated id" do
    test_pid = self()

    {:ok, config} =
      Config.new(
        adapters: [Adapter],
        model: "loader-test/model",
        tools: [],
        id_generator: fn ->
          send(test_pid, :id_generated)
          "generated-id"
        end
      )

    projection =
      Projection.new(
        %{
          "session_id" => "persisted-session",
          "created_at" => "2026-01-01T00:00:00Z",
          "cwd" => nil,
          "parent" => nil
        },
        model_ref: config.model_ref
      )

    assert {:ok, %{state: state}} = Loader.load(projection, config)
    assert state.session_id == "persisted-session"
    refute_receive :id_generated
  end
end
