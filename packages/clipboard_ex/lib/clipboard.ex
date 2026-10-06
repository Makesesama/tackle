defmodule Clipboard do
  @moduledoc """
  System clipboard access backed by Rust's `arboard`, with terminal fallbacks.

  Native operations go through `Clipboard.Owner`, a process that keeps the
  clipboard handle alive so Linux (X11/Wayland) contents stay pasteable after a
  copy. It is started with the `:clipboard_ex` application.

  ## Copying text

  `copy/2` tries the native clipboard first and reaches the user's terminal
  through tmux or OSC 52 (see `Clipboard.Terminal`):

    * when the native copy fails, or
    * always, inside tmux or over SSH, where the native clipboard may belong to
      another machine than the one the user is sitting at.

  The native copy runs first, so a terminal write cannot race the display
  server's selection ownership. The result tells how certain the copy is:

    * `{:ok, :confirmed}` - the native clipboard accepted the text.
    * `{:ok, :requested}` - only the terminal was asked; terminals never
      acknowledge OSC 52, so the copy may or may not have happened.
    * `{:error, {:copy_failed, attempts}}` - every attempt failed;
      `attempts` lists `{transport, reason}` in the order they were tried.

  ## Native-only operations

  `read_text/1`, `read_html/1`, `read_image/1`, `copy_image/2`, and `clear/1`
  use the native clipboard alone.

  ## Common options

    * `:selection` - `:clipboard` (default), or the Linux `:primary` and
      `:secondary` selections. Other platforms return
      `{:error, :unsupported_selection}` for those; Wayland compositors without
      support (always for `:secondary`) return `{:error, :clipboard_not_supported}`.
    * `:owner` - the `Clipboard.Owner` to use, defaults to `Clipboard.Owner`.
    * `:timeout` - milliseconds to wait for the native clipboard, default 5000.
  """

  alias Clipboard.{Environment, Image, Owner, Terminal}

  @selections [:clipboard, :primary, :secondary]
  @native_options [selection: :clipboard, owner: Owner, timeout: 5_000]

  @type selection :: :clipboard | :primary | :secondary
  @type transport :: :native | :tmux | :osc52
  @type copy_error :: :empty | :invalid_utf8 | {:copy_failed, [{transport(), term()}]}

  @doc """
  Copies `text` to the clipboard.

  Options, besides the common ones:

    * `:html` - an HTML rendering of `text`. The native clipboard then offers
      both, so rich-text applications paste the HTML and everything else the
      plain text. When the native clipboard rejects HTML, the plain text alone
      is retried. Terminal transports carry `text` only.
    * `:terminal` - `:auto` (default) to use terminal transports as described
      in the module docs, or `:never` for native only. Terminal transports are
      never used for the `:primary` or `:secondary` selections.
    * `:environment` - a `Clipboard.Environment`, defaults to
      `Clipboard.Environment.detect/0`.
    * `:osc52_writer` - a function delivering the OSC 52 sequence, for callers
      that own terminal output; defaults to `Clipboard.Terminal.write_tty/1`.

  Empty text and invalid UTF-8 are rejected without touching any clipboard.
  """
  @spec copy(binary(), keyword()) :: {:ok, :confirmed | :requested} | {:error, copy_error()}
  def copy(text, opts \\ []) when is_binary(text) do
    opts =
      Keyword.validate!(
        opts,
        @native_options ++
          [html: nil, terminal: :auto, environment: nil, osc52_writer: &Terminal.write_tty/1]
      )

    selection = selection!(opts)
    terminal_mode!(opts)
    html!(opts)

    cond do
      text == "" ->
        {:error, :empty}

      not String.valid?(text) ->
        {:error, :invalid_utf8}

      true ->
        native = fn -> native_copy(text, selection, opts) end
        environment = opts[:environment] || Environment.detect()
        terminal = terminal_copy(text, selection, environment, Map.new(opts))
        cascade(native, terminal, Environment.remote?(environment))
    end
  end

  @doc "Reads text from the clipboard."
  @spec read_text(keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_text(opts \\ []), do: native(:get_text, [], opts)

  @doc "Reads HTML from the clipboard."
  @spec read_html(keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_html(opts \\ []), do: native(:get_html, [], opts)

  @doc """
  Reads an image from the clipboard as RGBA pixels.

  Returns `{:error, :content_not_available}` when the clipboard holds no
  image in a format the platform can decode.
  """
  @spec read_image(keyword()) :: {:ok, Image.t()} | {:error, term()}
  def read_image(opts \\ []) do
    with {:ok, {width, height, rgba}} <- native(:get_image, [], opts) do
      {:ok, %Image{width: width, height: height, rgba: rgba}}
    end
  end

  @doc """
  Copies an RGBA image to the clipboard through the native clipboard.

  Returns `{:error, :invalid_image}` when the pixel buffer does not match the
  dimensions.
  """
  @spec copy_image(Image.t(), keyword()) :: :ok | {:error, term()}
  def copy_image(%Image{} = image, opts \\ []) do
    if Image.valid?(image) do
      native(:set_image, [image.width, image.height, image.rgba], opts)
    else
      {:error, :invalid_image}
    end
  end

  @doc "Clears the clipboard."
  @spec clear(keyword()) :: :ok | {:error, term()}
  def clear(opts \\ []), do: native(:clear, [], opts)

  @doc false
  # The copy order shared with Codex: native first; terminal eagerly when the
  # session is remote, otherwise only after a native failure. `terminal` is
  # `nil` when terminal transports are disabled.
  @spec cascade(
          (-> :ok | {:error, term()}),
          (-> :ok | {:error, [{transport(), term()}]}) | nil,
          boolean()
        ) :: {:ok, :confirmed | :requested} | {:error, copy_error()}
  def cascade(native, terminal, remote?) do
    native_result = native.()
    terminal_result = if terminal && remote?, do: terminal.()

    case {native_result, terminal} do
      {:ok, _terminal} ->
        {:ok, :confirmed}

      {{:error, reason}, nil} ->
        {:error, {:copy_failed, [native: reason]}}

      {{:error, reason}, terminal} ->
        case terminal_result || terminal.() do
          :ok -> {:ok, :requested}
          {:error, attempts} -> {:error, {:copy_failed, [{:native, reason} | attempts]}}
        end
    end
  end

  # -- helpers -------------------------------------------------------------

  defp native_copy(text, selection, opts) do
    case opts[:html] do
      nil ->
        request(opts, :set_text, [selection, text])

      html ->
        # Like Codex: a clipboard that rejects HTML may still take plain text.
        # Failures of the owner itself would only repeat, so they are final.
        case request(opts, :set_html, [selection, html, text]) do
          {:error, reason} ->
            if owner_failure?(reason),
              do: {:error, reason},
              else: request(opts, :set_text, [selection, text])

          :ok ->
            :ok
        end
    end
  end

  defp owner_failure?(:timeout), do: true
  defp owner_failure?(:owner_not_running), do: true
  defp owner_failure?({:owner_exit, _reason}), do: true
  defp owner_failure?(_reason), do: false

  defp html!(opts) do
    case opts[:html] do
      nil ->
        nil

      html when is_binary(html) and html != "" ->
        if String.valid?(html),
          do: html,
          else: raise(ArgumentError, "expected :html to be valid UTF-8")

      other ->
        raise ArgumentError, "expected :html to be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp terminal_copy(text, :clipboard, environment, %{terminal: :auto} = opts),
    do: fn -> Terminal.copy(text, environment, writer: opts.osc52_writer) end

  defp terminal_copy(_text, _selection, _environment, _opts), do: nil

  defp terminal_mode!(opts) do
    case opts[:terminal] do
      mode when mode in [:auto, :never] ->
        mode

      other ->
        raise ArgumentError, "expected :terminal to be :auto or :never, got: #{inspect(other)}"
    end
  end

  defp native(function, args, opts) do
    opts = Keyword.validate!(opts, @native_options)
    request(opts, function, [selection!(opts) | args])
  end

  defp request(opts, function, args),
    do: Owner.request(opts[:owner], function, args, opts[:timeout])

  defp selection!(opts) do
    case opts[:selection] do
      selection when selection in @selections ->
        selection

      other ->
        raise ArgumentError,
              "expected :selection to be one of #{inspect(@selections)}, got: #{inspect(other)}"
    end
  end
end
