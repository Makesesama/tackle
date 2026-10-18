defmodule Tackle.HubWeb.ReviewRequestComponent do
  @moduledoc """
  Requests a review of a pull request from the web pages, for the owner of
  the repository's installation: what a `/tackle review [profile]` comment
  does (`Tackle.Hub.Triggers.owner_command/4`), with the owner's GitHub
  login and write access. On a repository's page it asks for the pull
  request's number; on a review's page (`pull_number` set) it reviews that
  pull request again.

  The forge calls run as an async task of the component; the result sends
  the browser to the review, or says why nothing was requested.
  """

  use Phoenix.LiveComponent

  import Tackle.HubWeb.UI, only: [sha: 1]

  alias Tackle.Hub.Reviews.{Profile, ReviewRequest}
  alias Tackle.Hub.Triggers
  alias Tackle.HubWeb.Auth

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:pull_number, fn -> nil end)
     |> assign_new(:busy, fn -> false end)
     |> assign_new(:notice, fn -> nil end)}
  end

  @impl true
  def handle_event("request", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("request", params, socket) do
    with {:ok, user} <- current_user(socket),
         {:ok, number} <- pull_number(socket.assigns.pull_number, params["pull_number"]),
         {:ok, profile} <- profile(params["profile"]) do
      repository = socket.assigns.repository

      {:noreply,
       socket
       |> assign(busy: true, notice: nil, current_user: user)
       |> start_async(:request, fn ->
         {number, Triggers.owner_command(user, repository, number, profile)}
       end)}
    else
      :signed_out -> {:noreply, Phoenix.LiveView.redirect(socket, to: "/")}
      {:invalid, notice} -> {:noreply, assign(socket, :notice, notice)}
    end
  end

  @impl true
  def handle_async(:request, {:ok, {number, result}}, socket) do
    {:noreply, socket |> assign(:busy, false) |> finish(number, result)}
  end

  def handle_async(:request, {:exit, _reason}, socket) do
    {:noreply, assign(socket, busy: false, notice: "The review could not be requested.")}
  end

  defp current_user(socket) do
    case Auth.current_user(socket) do
      {:ok, user} -> {:ok, user}
      :error -> :signed_out
    end
  end

  # The page's pull request, or the number typed in.
  defp pull_number(number, _param) when is_integer(number), do: {:ok, number}

  defp pull_number(nil, param) when is_binary(param) do
    case Integer.parse(String.trim(param)) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:invalid, "Enter the number of a pull request."}
    end
  end

  defp pull_number(nil, _param), do: {:invalid, "Enter the number of a pull request."}

  defp profile(value) when value in [nil, ""], do: {:ok, nil}

  defp profile(value) do
    case Profile.match(value) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:invalid, "Choose a profile."}
    end
  end

  # What a request led to: the review's page, or a notice why not.
  defp finish(socket, number, {:ok, outcome, %ReviewRequest{} = request})
       when outcome in [:created, :rerun] do
    socket
    |> put_flash(:info, "Reviewing ##{number} at #{short(request.head_sha)}.")
    |> push_navigate(to: "/reviews/#{request.id}")
  end

  defp finish(socket, number, {:ok, :exists, %ReviewRequest{status: status} = request})
       when status in [:pending, :running, :reviewed] do
    socket
    |> put_flash(:info, "##{number} at #{short(request.head_sha)} is being reviewed already.")
    |> push_navigate(to: "/reviews/#{request.id}")
  end

  defp finish(socket, _number, {:ok, :exists, %ReviewRequest{} = request}) do
    assign(socket, :notice, {:reviewed, request})
  end

  defp finish(socket, number, {:ok, :closed, _request}),
    do: assign(socket, :notice, "Pull request ##{number} is closed.")

  defp finish(socket, _number, {:ok, :disabled, _request}),
    do: assign(socket, :notice, "Reviews are off for this repository.")

  defp finish(socket, _number, {:error, :not_owner}),
    do: assign(socket, :notice, "Only the installation's owner requests reviews here.")

  defp finish(socket, _number, {:error, :no_write_access}),
    do: assign(socket, :notice, "GitHub says you have no write access to this repository.")

  defp finish(socket, number, {:error, {:github, 404, _message}}),
    do: assign(socket, :notice, "GitHub has no pull request ##{number} in this repository.")

  defp finish(socket, _number, _other),
    do: assign(socket, :notice, "GitHub could not be asked about the pull request. Try again.")

  defp short(sha), do: String.slice(sha, 0, 7)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="review-request">
      <form phx-submit="request" phx-target={@myself} class="row">
        <div :if={!@pull_number} class="field">
          <label for={"#{@id}-number"}>Pull request</label>
          <input
            id={"#{@id}-number"}
            name="pull_number"
            type="number"
            min="1"
            placeholder="12"
            required
            class="number"
          />
        </div>
        <div class="field">
          <label for={"#{@id}-profile"}>Profile</label>
          <select id={"#{@id}-profile"} name="profile">
            <option value="">The repository's ({@repository.profile})</option>
            <option :for={profile <- Profile.values()} value={profile}>{profile}</option>
          </select>
        </div>
        <button type="submit" disabled={@busy} phx-disable-with="Asking GitHub…">
          {if @busy, do: "Asking GitHub…", else: @label}
        </button>
      </form>
      <p class="help">
        Reviews the pull request's current head, as a <code>/tackle review</code>
        comment from you would.
      </p>
      <p :if={is_binary(@notice)} class="notice">{@notice}</p>
      <p :if={match?({:reviewed, _}, @notice)} class="notice">
        <.link navigate={"/reviews/#{elem(@notice, 1).id}"}>
          Its current head <.sha sha={elem(@notice, 1).head_sha} />
        </.link>
        was already reviewed with the {elem(@notice, 1).profile} profile. Choose another profile
        to review it again.
      </p>
    </div>
    """
  end
end
