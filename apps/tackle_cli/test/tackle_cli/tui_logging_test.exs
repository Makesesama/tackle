defmodule Tackle.CLI.TUI.LoggingTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.TUI.Logging

  test "filters console logging only while the shell is active" do
    assert {:ok, before} = :logger.get_handler_config(:default)
    refute Keyword.has_key?(before.filters, :tackle_cli_tui_console)

    assert :ok =
             Logging.with_quiet_console(fn ->
               assert {:ok, during} = :logger.get_handler_config(:default)
               assert Keyword.has_key?(during.filters, :tackle_cli_tui_console)
               :ok
             end)

    assert {:ok, after_config} = :logger.get_handler_config(:default)
    refute Keyword.has_key?(after_config.filters, :tackle_cli_tui_console)
  end

  test "removes the filter when the shell raises" do
    assert_raise RuntimeError, "shell failed", fn ->
      Logging.with_quiet_console(fn -> raise "shell failed" end)
    end

    assert {:ok, config} = :logger.get_handler_config(:default)
    refute Keyword.has_key?(config.filters, :tackle_cli_tui_console)
  end
end
