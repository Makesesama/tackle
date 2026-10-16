defmodule Tackle.Web.Application do
  @moduledoc false

  use Application

  alias Tackle.Web.{Endpoint, Setup}

  @impl Application
  def start(_type, _args) do
    Setup.init_token()

    children = [
      Tackle.Web.Vault,
      Tackle.Web.Repo,
      Tackle.Web.ReviewJob.Sweeper,
      {Oban, oban_config()},
      Tackle.Web.Forge.GitHub.TokenCache,
      {Phoenix.PubSub, name: Tackle.Web.PubSub},
      Endpoint,
      # After the endpoint: the message names its URL.
      announce_setup()
    ]

    Supervisor.start_link(List.flatten(children),
      strategy: :one_for_one,
      name: Tackle.Web.Supervisor
    )
  end

  @impl Application
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  # Logs the setup token while setup is incomplete (Tackle.Web.Setup); off in
  # tests. A temporary task: it runs once and is not restarted.
  defp announce_setup do
    if Application.get_env(:tackle_web, :announce_setup, true),
      do: {Task, &Setup.announce/0},
      else: []
  end

  # AshOban adds the queues and cron jobs of the resources' triggers.
  defp oban_config do
    AshOban.config(
      Application.fetch_env!(:tackle_web, :ash_domains),
      Application.fetch_env!(:tackle_web, Oban)
    )
  end
end
