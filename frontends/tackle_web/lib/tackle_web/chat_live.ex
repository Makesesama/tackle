defmodule Tackle.Web.ChatLive do
  @moduledoc """
  The chat frontend's start page: the conversations held in memory, and the form
  that starts another one.

  Starting a conversation asks for two things, and both are recorded on the
  conversation rather than kept in the browser: the directory the assistant
  works in, and the model it runs. They are recorded because they are part of
  what the conversation is — the first decides which files every question is
  answered from, the second decides which provider answers it — and because a
  conversation opened later from the list has to resume both.

  Conversations are not written to disk. `Tackle.Web.ChatStore` says what that
  means and where a durable store would take over.
  """

  use Tackle.Web, :live_view

  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatError
  alias Tackle.Web.ChatStore
  alias Tackle.Web.Components.Chat

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ChatStore.subscribe()

    models = ChatAgent.models()

    {:ok,
     socket
     |> assign(
       section: :chat,
       page_title: "Chat",
       conversations: ChatStore.list(),
       models: models,
       error: nil
     )
     |> assign_form(ChatAgent.default_cwd(), selected_model(models))}
  end

  @impl true
  def handle_info({:chat_updated, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:chat_deleted, _id}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("create", %{"chat" => params}, socket) do
    with {:ok, model} <- pick_model(params["model"]),
         {:ok, conversation} <- ChatStore.create(cwd: workspace(params), model: model) do
      {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation.id}")}
    else
      {:error, reason} -> {:noreply, assign(socket, :error, ChatError.message(reason))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    ChatStore.delete(id)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket), do: assign(socket, :conversations, ChatStore.list())

  defp assign_form(socket, workspace, model) do
    form = to_form(%{"workspace" => workspace, "model" => model}, as: :chat)

    assign(socket, :form, form)
  end

  defp workspace(%{"workspace" => workspace}) when is_binary(workspace), do: workspace
  defp workspace(_params), do: ChatAgent.default_cwd()

  # The select only offers models the configured adapters expose, so an unknown
  # value means the form was posted from a page built against another
  # configuration. Fail closed rather than starting a conversation that cannot
  # answer.
  defp pick_model(selected) do
    models = ChatAgent.models()

    selected =
      if is_binary(selected) and selected != "", do: selected, else: selected_model(models)

    cond do
      is_nil(selected) -> {:error, :no_model_available}
      selected in models -> {:ok, selected}
      true -> {:error, {:unknown_model, selected}}
    end
  end

  # The configured default may name a model no adapter offers any more; the
  # first offered model is a better starting point than an invalid selection.
  defp selected_model(models) do
    default = ChatAgent.default_model()
    if default in models, do: default, else: List.first(models)
  end
end
