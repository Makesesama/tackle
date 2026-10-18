defmodule Tackle.HubWeb.Live do
  @moduledoc """
  What the signed-in LiveView pages share (docs/TACKLE_HUB_PLAN.md §8,
  phase 8). They mount behind `{Tackle.HubWeb.Auth, :require_user}`, read
  everything with the signed-in user as the actor, and:

    * re-read the user before every event and update (`with_user/2`), so
      an expired sign-in or a deleted user stops a page that stays open;
    * follow what they show while connected (`follow/2`): a committed
      change on one of their topics (`Tackle.Hub.Updates`) reads the page
      again (`changed/1`, then `:reload`), once for a burst of changes;
    * show the progress of the reviews in flight on them (`track_progress/2`,
      `put_progress/4`, `progress/2`; `Tackle.Hub.ReviewProgress`).

  A page handles the messages itself:

      def handle_info({Tackle.Hub.Updates, _topic}, socket), do: {:noreply, changed(socket)}
      def handle_info(:reload, socket), do: with_user(reloading(socket), &load/1)

      def handle_info({Tackle.Hub.ReviewProgress, id, version, progress}, socket),
        do: with_user(socket, &put_progress(&1, id, version, progress))
  """

  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, push_navigate: 2, redirect: 2]

  alias Phoenix.LiveView.Socket
  alias Tackle.Hub.{ReviewProgress, Updates}
  alias Tackle.HubWeb.Auth

  @doc """
  Subscribes the connected page to exactly `topics` (`Tackle.Hub.Updates`):
  to the new ones, and no longer to those it followed before and are not
  given now. Does nothing before the page is connected.
  """
  @spec follow(Socket.t(), [String.t()]) :: Socket.t()
  def follow(socket, topics) do
    if connected?(socket) do
      followed = Map.get(socket.assigns, :followed, MapSet.new())
      topics = MapSet.new(topics)

      Enum.each(MapSet.difference(topics, followed), &Updates.subscribe/1)
      Enum.each(MapSet.difference(followed, topics), &Updates.unsubscribe/1)
      Phoenix.Component.assign(socket, :followed, topics)
    else
      socket
    end
  end

  @doc """
  Something the page shows changed: it gets `:reload` once, however many
  changes arrive before it handles that.
  """
  @spec changed(Socket.t()) :: Socket.t()
  def changed(socket) do
    if Map.get(socket.assigns, :reload_pending, false) do
      socket
    else
      send(self(), :reload)
      Phoenix.Component.assign(socket, :reload_pending, true)
    end
  end

  @doc "The page handles its `:reload`: later changes send another."
  @spec reloading(Socket.t()) :: Socket.t()
  def reloading(socket), do: Phoenix.Component.assign(socket, :reload_pending, false)

  @doc """
  Keeps the progress of the review requests `ids` in the `:progress`
  assign (`progress/2` reads it): the latest of what the page has and what
  the jobs on this node report now. Requests not in `ids` are dropped.
  Follow their topics (`Tackle.Hub.Updates.review/1`) to get the changes.
  """
  @spec track_progress(Socket.t(), [Ecto.UUID.t()]) :: Socket.t()
  def track_progress(socket, ids) do
    known = Map.get(socket.assigns, :progress, %{})

    progress =
      Map.new(ids, fn id ->
        {version, _progress} = entry = Map.get(known, id, {0, nil})

        case ReviewProgress.current(id) do
          %ReviewProgress{version: newer} = current when newer > version -> {id, {newer, current}}
          _older_or_none -> {id, entry}
        end
      end)

    Phoenix.Component.assign(socket, :progress, progress)
  end

  @doc """
  Takes a progress message for a tracked request when it is newer than
  what the page has; `nil` progress means its job stopped reporting.
  """
  @spec put_progress(Socket.t(), Ecto.UUID.t(), integer(), ReviewProgress.t() | nil) ::
          Socket.t()
  def put_progress(socket, id, version, progress) do
    case Map.get(socket.assigns, :progress, %{}) do
      %{^id => {known, _progress}} = all when version > known ->
        Phoenix.Component.assign(socket, :progress, Map.put(all, id, {version, progress}))

      _untracked_or_older ->
        socket
    end
  end

  @doc "The progress of a tracked request, or nil."
  @spec progress(
          %{optional(Ecto.UUID.t()) => {integer(), ReviewProgress.t() | nil}},
          Ecto.UUID.t()
        ) ::
          ReviewProgress.t() | nil
  def progress(progress, id) do
    case Map.get(progress, id) do
      {_version, progress} -> progress
      nil -> nil
    end
  end

  @doc """
  Runs `fun` with the signed-in user, read again, as the page's
  `current_user`; sends the browser to the start page when the sign-in is
  no longer valid. `fun` returns the socket.
  """
  @spec with_user(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                                  Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def with_user(socket, fun) do
    case Auth.current_user(socket) do
      {:ok, user} -> {:noreply, fun.(Phoenix.Component.assign(socket, :current_user, user))}
      :error -> {:noreply, redirect(socket, to: "/")}
    end
  end

  @doc "Leaves a page whose record the user cannot see (or that does not exist)."
  @spec not_found(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def not_found(socket) do
    {:ok,
     socket
     |> put_flash(:error, "That page does not exist, or you have no access to it.")
     |> push_navigate(to: "/repos")}
  end

  @doc "Reads one record as `actor`: nil when it is missing, hidden, or the id is invalid."
  @spec get(Ash.Resource.t(), term(), Tackle.Hub.Accounts.User.t(), keyword()) ::
          Ash.Resource.record() | nil
  def get(resource, id, actor, opts \\ []) do
    case Ash.get(resource, id, Keyword.merge([actor: actor, not_found_error?: false], opts)) do
      {:ok, record} -> record
      {:error, _invalid_or_forbidden} -> nil
    end
  end
end
