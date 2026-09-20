defmodule Tackle.Web.ProjectLive do
  @moduledoc """
  One project: the reviews you can open in it, and the chats held in it.

  What this page offers depends on the project's source, not on the page. A
  local repository lists branches to compare, a GitHub repository lists its open
  pull requests, and both arrive through `Tackle.Web.Projects` — see
  `Tackle.Web.Project.Source`. A source may offer either, both, or neither, and
  the page simply renders what it is given.

  Chats are scoped to the project, so starting one here asks the source for a
  working tree and records that directory on the conversation. That is the whole
  of the project's involvement in a chat: the checkout it runs the assistant in.
  """

  use Tackle.Web, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatError
  alias Tackle.Web.ChatStore
  alias Tackle.Web.Project
  alias Tackle.Web.Projects

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get(slug) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      project ->
        if connected?(socket), do: ChatStore.subscribe()

        {:ok,
         socket
         |> assign(
           section: :projects,
           page_title: project.name,
           project: project,
           slug: slug,
           chats: ChatStore.list(slug),
           models: ChatAgent.models(),
           creating: false,
           error: nil,
           reviews: AsyncResult.loading(),
           branches: AsyncResult.loading()
         )
         |> start_async(:reviews, fn -> Projects.list_reviews(project) end)
         |> start_async(:branches, fn -> Projects.branches(project) end)}
    end
  end

  @impl true
  def handle_async(:reviews, {:ok, result}, socket) do
    {:noreply, assign(socket, :reviews, async(socket.assigns.reviews, result))}
  end

  def handle_async(:reviews, {:exit, reason}, socket) do
    {:noreply, assign(socket, :reviews, AsyncResult.failed(socket.assigns.reviews, reason))}
  end

  def handle_async(:branches, {:ok, result}, socket) do
    {:noreply, assign(socket, :branches, async(socket.assigns.branches, result))}
  end

  def handle_async(:branches, {:exit, reason}, socket) do
    {:noreply, assign(socket, :branches, AsyncResult.failed(socket.assigns.branches, reason))}
  end

  # A first chat in a GitHub project clones the repository, which is not
  # instantaneous, so the checkout happens in a task and the page navigates when
  # it is done.
  def handle_async(:chat, {:ok, {:ok, conversation}}, socket) do
    {:noreply,
     push_navigate(socket, to: ~p"/projects/#{socket.assigns.slug}/chats/#{conversation.id}")}
  end

  def handle_async(:chat, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(creating: false) |> assign(:error, ChatError.message(reason))}
  end

  def handle_async(:chat, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(creating: false)
     |> assign(:error, "Could not start the conversation: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:chat_updated, _id}, socket), do: {:noreply, refresh_chats(socket)}
  def handle_info({:chat_deleted, _id}, socket), do: {:noreply, refresh_chats(socket)}

  @impl true
  def handle_event("review", %{"review" => params}, socket) do
    base = params |> Map.get("base", "") |> String.trim()
    head = params |> Map.get("head", "") |> String.trim()

    if base == "" or head == "" do
      {:noreply, assign(socket, :error, "Pick both ends of the diff.")}
    else
      review_id = Project.ref_review_id(base, head)

      {:noreply,
       push_navigate(socket, to: ~p"/projects/#{socket.assigns.slug}/reviews/#{review_id}")}
    end
  end

  @impl true
  def handle_event("new_chat", %{"chat" => %{"model" => model}}, socket) do
    project = socket.assigns.project

    {:noreply,
     socket
     |> assign(creating: true, error: nil)
     |> start_async(:chat, fn -> create_chat(project, model) end)}
  end

  @impl true
  def handle_event("delete_chat", %{"id" => id}, socket) do
    ChatStore.delete(id)
    {:noreply, refresh_chats(socket)}
  end

  defp create_chat(project, model) do
    with {:ok, cwd} <- Projects.checkout(project) do
      ChatStore.create(project_slug: project.slug, cwd: cwd, model: model)
    end
  end

  defp refresh_chats(socket), do: assign(socket, :chats, ChatStore.list(socket.assigns.slug))

  defp async(result, {:ok, value}), do: AsyncResult.ok(result, value)
  defp async(result, {:error, reason}), do: AsyncResult.failed(result, {:error, reason})

  # -- template helpers -----------------------------------------------------

  defp branch_names(branches), do: Enum.map(branches, & &1.name)

  defp default_base(branches, project) do
    names = branch_names(branches)

    if project.default_branch in names, do: project.default_branch, else: List.first(names) || ""
  end

  defp default_head(branches) do
    branch = Enum.find(branches, & &1.current?) || List.first(branches)

    case branch do
      nil -> ""
      %{name: name} -> name
    end
  end

  defp default_model(models) do
    if ChatAgent.default_model() in models,
      do: ChatAgent.default_model(),
      else: List.first(models)
  end

  defp no_reviews?(reviews, branches) do
    ok?(reviews) and ok?(branches) and reviews.result == [] and branches.result == []
  end

  defp ok?(%AsyncResult{ok?: true}), do: true
  defp ok?(_result), do: false
end
