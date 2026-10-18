defmodule Tackle.Hub.Application do
  @moduledoc false

  use Application

  alias Tackle.Hub.Setup
  alias Tackle.HubWeb.Endpoint

  @impl Application
  def start(_type, _args) do
    Setup.init_token()

    children = [
      Tackle.Hub.Vault,
      Tackle.Hub.Repo,
      # Before anything that writes: writes notify the pages over PubSub
      # (Tackle.Hub.Updates), and review jobs report their progress.
      {Phoenix.PubSub, name: Tackle.Hub.PubSub},
      Tackle.Hub.ReviewProgress,
      Tackle.Hub.ReviewJob.Sweeper,
      {Oban, oban_config()},
      Tackle.Hub.Forge.GitHub.TokenCache,
      Endpoint,
      # After the endpoint: the message names its URL.
      announce_setup()
    ]

    Supervisor.start_link(List.flatten(children),
      strategy: :one_for_one,
      name: Tackle.Hub.Supervisor
    )
  end

  @impl Application
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  # Logs the setup token while setup is incomplete (Tackle.Hub.Setup); off in
  # tests. A temporary task: it runs once and is not restarted.
  defp announce_setup do
    if Application.get_env(:tackle_hub, :announce_setup, true),
      do: {Task, &Setup.announce/0},
      else: []
  end

  # AshOban adds the queues and cron jobs of the resources' triggers.
  defp oban_config do
    AshOban.config(
      Application.fetch_env!(:tackle_hub, :ash_domains),
      Application.fetch_env!(:tackle_hub, Oban)
    )
  end
end
