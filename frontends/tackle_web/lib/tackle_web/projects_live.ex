defmodule Tackle.Web.ProjectsLive do
  @moduledoc """
  The projects this frontend knows about, and the form that adds another.

  A project is the place the assistant works and the scope every chat and review
  lives in, so this is the front door: adding one asks a source to describe a
  local repository or a GitHub repository, and opening one shows what is inside
  it.

  The list is in memory — see `Tackle.Web.ProjectStore` — so a restart starts
  from an empty list and adding the same locator again is how a project comes
  back.
  """

  use Tackle.Web, :live_view

  alias Tackle.Web.Project
  alias Tackle.Web.Projects

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Projects.subscribe()

    {:ok,
     socket
     |> assign(
       section: :projects,
       page_title: "Projects",
       projects: Projects.list(),
       kinds: Projects.kinds(),
       error: nil
     )}
  end

  @impl true
  def handle_info({:projects_updated, _topic}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("add", %{"project" => params}, socket) do
    case Projects.create(params) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project.slug}")}

      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("remove", %{"slug" => slug}, socket) do
    Projects.remove(slug)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket), do: assign(socket, :projects, Projects.list())
end
