defmodule Tackle.CLI.TUI.Logging do
  @moduledoc """
  Prevents the OTP console logger from painting over the interactive screen.

  The filter is attached to the console handler, not the primary logger: other
  installed handlers continue to receive events. It is removed when the shell
  exits, including when the shell raises.
  """

  @filter :tackle_cli_tui_console

  @spec with_quiet_console((-> result)) :: result when result: var
  def with_quiet_console(fun) when is_function(fun, 0) do
    case :logger.add_handler_filter(:default, @filter, {&__MODULE__.mute/2, []}) do
      :ok ->
        try do
          fun.()
        after
          :logger.remove_handler_filter(:default, @filter)
        end

      {:error, {:already_exist, @filter}} ->
        fun.()

      {:error, {:not_found, :default}} ->
        fun.()

      {:error, reason} ->
        {:error, {:tui_logger_filter_failed, reason}}
    end
  end

  @doc false
  def mute(_event, _config), do: :stop
end
