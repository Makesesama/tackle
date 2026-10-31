defmodule Tackle.Phoenix.Test.LiveHarness do
  @moduledoc false

  # Runs a LiveView module's callbacks in one process, as a connected LiveView
  # does: `mount/3`, then every message the process receives through
  # `handle_info/2`, and UI events through `handle_event/3`. It renders
  # nothing (`Phoenix.LiveViewTest` needs `lazy_html`, which is not a
  # dependency), so tests read the assigns.

  use GenServer

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  def start_link(view, session), do: GenServer.start_link(__MODULE__, {view, session})

  @doc "Sends a UI event, as a `phx-click` or form submission would."
  def event(pid, name, params \\ %{}), do: GenServer.call(pid, {:event, name, params})

  def assigns(pid), do: GenServer.call(pid, :assigns)

  @impl true
  def init({view, session}) do
    socket = %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}, lifecycle: %Lifecycle{}}
    }

    {:ok, socket} = view.mount(%{}, session, socket)
    {:ok, %{view: view, socket: socket}}
  end

  @impl true
  def handle_call({:event, name, params}, _from, state) do
    {:noreply, socket} = state.view.handle_event(name, params, state.socket)
    {:reply, :ok, %{state | socket: socket}}
  end

  def handle_call(:assigns, _from, state), do: {:reply, state.socket.assigns, state}

  @impl true
  def handle_info(message, state) do
    {:noreply, socket} = state.view.handle_info(message, state.socket)
    {:noreply, %{state | socket: socket}}
  end
end
