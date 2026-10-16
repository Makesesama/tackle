defmodule Tackle.Web.ReviewJob.Sweeper do
  @moduledoc false
  use GenServer

  alias Tackle.Web.Checkout

  # Starts before Oban consumers. Missing databases/tables (mix ash.setup) and
  # missing state configuration must not prevent application/migration startup.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, state}
  end

  defp sweep do
    if Application.get_env(:tackle_web, :state_dir), do: Checkout.sweep()
    # Revisit after Lifeline has recovered orphaned executing jobs. Checkout
    # fails closed on DB errors and protects all globally leased live worktrees.
    Process.send_after(self(), :sweep, :timer.minutes(1))
  end
end
