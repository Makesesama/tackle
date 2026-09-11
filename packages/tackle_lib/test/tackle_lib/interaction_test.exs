defmodule Tackle.Lib.InteractionTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Interaction

  defmodule Recorder do
    @behaviour Tackle.Lib.Interaction

    @impl true
    def info(reference, message) do
      send(reference, {:info, IO.iodata_to_binary(message)})
      :ok
    end

    @impl true
    def prompt(reference, opts) do
      send(reference, {:prompt, opts})
      {:ok, "typed-value"}
    end

    @impl true
    def confirm(reference, message) do
      send(reference, {:confirm, IO.iodata_to_binary(message)})
      true
    end

    @impl true
    def progress(reference, opts, fun) do
      send(reference, {:progress, opts})
      fun.()
    end
  end

  test "routes calls to the implementation module with the opaque reference" do
    handle = {Recorder, self()}

    assert :ok = Interaction.info(handle, ["Hello", " ", "world"])
    assert_received {:info, "Hello world"}

    assert {:ok, "typed-value"} = Interaction.prompt(handle, label: "Token", secret: true)
    assert_received {:prompt, [label: "Token", secret: true]}

    assert Interaction.confirm(handle, "Continue?") == true
    assert_received {:confirm, "Continue?"}

    assert Interaction.progress(handle, [label: "Waiting..."], fn -> :done end) == :done
    assert_received {:progress, [label: "Waiting..."]}
  end
end
