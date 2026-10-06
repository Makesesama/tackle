defmodule Clipboard.Owner do
  @moduledoc """
  Owns the native clipboard handle.

  On X11 and Wayland, nothing is sent anywhere when text is copied: the process
  that set the clipboard serves its contents whenever another application
  pastes. Dropping the handle can make the contents vanish. This process keeps
  one handle for as long as it runs, so copies stay pasteable. macOS and Windows
  do not need that, but sharing one path keeps behaviour uniform.

  `Clipboard` starts one owner named `Clipboard.Owner` under its
  application. Start another with `start_link/1` and pass it as `:owner` to
  isolate a component.

  The handle is opened lazily on first use. When opening fails, for example
  because no display server is reachable yet, the error is returned and the
  next request tries again. Native calls are serialised through this process;
  a request that exceeds its timeout returns `{:error, :timeout}` while the
  native call keeps running to completion.

  On shutdown the handle is closed explicitly. On X11 that offers the current
  contents to a clipboard manager, waiting up to a few seconds, so the shutdown
  timeout is generous. If the owner is killed instead, the handle is released
  whenever it is garbage collected, and after `System.halt/1` possibly never,
  in which case the contents are not handed over.
  """

  use GenServer, shutdown: 10_000

  @native_functions [:set_text, :set_html, :get_text, :get_html, :set_image, :get_image, :clear]

  @typedoc "A native function invoked with the handle prepended to its arguments."
  @type native_function ::
          :set_text | :set_html | :get_text | :get_html | :set_image | :get_image | :clear

  @doc """
  Starts an owner.

  Options:

    * `:name` - registered name, defaults to `Clipboard.Owner`; pass `nil`
      for an unnamed owner.
    * `:native` - module implementing the native functions, defaults to
      `Clipboard.Native`. Intended for tests.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Runs a native clipboard function with the owned handle.

  Does not exit: an owner that is not running, crashes, or exceeds `timeout`
  produces an error tuple.
  """
  @spec request(GenServer.server(), native_function(), [term()], timeout()) :: term()
  def request(server, function, args, timeout)
      when function in @native_functions and is_list(args) do
    GenServer.call(server, {:native, function, args}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :owner_not_running}
    :exit, {reason, _call} -> {:error, {:owner_exit, reason}}
  end

  @impl true
  def init(opts) do
    # Trapping exits makes a supervisor shutdown run `terminate/2`.
    Process.flag(:trap_exit, true)
    {:ok, %{native: Keyword.get(opts, :native, Clipboard.Native), handle: nil}}
  end

  @impl true
  def handle_call({:native, function, args}, _from, state) do
    case ensure_handle(state) do
      {:ok, state} ->
        {:reply, invoke(state.native, function, [state.handle | args]), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{handle: nil}), do: :ok
  def terminate(_reason, state), do: invoke(state.native, :close, [state.handle])

  defp ensure_handle(%{handle: nil} = state) do
    case invoke(state.native, :new, []) do
      {:ok, handle} -> {:ok, %{state | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_handle(state), do: {:ok, state}

  # A missing or panicking NIF raises; report it instead of crashing the owner
  # and losing the handle that serves the current clipboard contents.
  defp invoke(native, function, args) do
    apply(native, function, args)
  rescue
    error -> {:error, {:native_error, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:native_error, {kind, reason}}}
  end
end
