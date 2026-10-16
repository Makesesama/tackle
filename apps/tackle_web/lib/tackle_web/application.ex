defmodule Tackle.Web.Application do
  @moduledoc false

  use Application

  alias Tackle.Web.Endpoint

  @impl Application
  def start(_type, _args) do
    children = [
      Tackle.Web.Vault,
      Tackle.Web.Repo,
      {Oban, oban_config()},
      {Phoenix.PubSub, name: Tackle.Web.PubSub},
      Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Tackle.Web.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  # AshOban adds the queues and cron jobs of the resources' triggers.
  defp oban_config do
    AshOban.config(
      Application.fetch_env!(:tackle_web, :ash_domains),
      Application.fetch_env!(:tackle_web, Oban)
    )
  end
end
