defmodule Tackle.Web.Live do
  @moduledoc """
  What the signed-in LiveView pages share (docs/TACKLE_WEB_PLAN.md §8,
  phase 8). They mount behind `{Tackle.Web.Auth, :require_user}`, read
  everything with the signed-in user as the actor, and:

    * re-read the user before every event and refresh (`with_user/2`), so
      an expired sign-in or a deleted user stops a page that stays open;
    * refresh themselves while connected (`schedule_refresh/1`), so review
      statuses follow the review jobs without a reload.
  """

  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, push_navigate: 2, redirect: 2]

  alias Tackle.Web.Auth

  @refresh_ms 10_000

  @doc "Sends the page `:refresh` in a while, when it is connected."
  @spec schedule_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    socket
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
  @spec get(Ash.Resource.t(), term(), Tackle.Web.Accounts.User.t(), keyword()) ::
          Ash.Resource.record() | nil
  def get(resource, id, actor, opts \\ []) do
    case Ash.get(resource, id, Keyword.merge([actor: actor, not_found_error?: false], opts)) do
      {:ok, record} -> record
      {:error, _invalid_or_forbidden} -> nil
    end
  end
end
