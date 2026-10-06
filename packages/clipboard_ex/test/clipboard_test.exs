defmodule ClipboardTest do
  use ExUnit.Case, async: false

  alias Clipboard.{Environment, FakeNative, Image, Owner}

  @local %Environment{}
  @ssh %Environment{ssh: true}

  setup do
    on_exit(&FakeNative.teardown/0)
    :ok
  end

  defp owner(responder) do
    test_pid = self()

    FakeNative.setup(test_pid, fn
      :new, [] -> {:ok, :handle}
      function, args -> responder.(function, args)
    end)

    start_supervised!({Owner, name: nil, native: FakeNative})
  end

  defp writer do
    test_pid = self()

    fn sequence ->
      send(test_pid, {:osc52, sequence})
      :ok
    end
  end

  describe "cascade/3" do
    test "a local native success is confirmed without touching the terminal" do
      terminal = fn -> flunk("terminal must not run") end
      assert Clipboard.cascade(fn -> :ok end, terminal, false) == {:ok, :confirmed}
    end

    test "a remote session also forwards to the terminal, yet stays confirmed" do
      terminal = fn ->
        send(self(), :terminal)
        {:error, [osc52: :enxio]}
      end

      assert Clipboard.cascade(fn -> :ok end, terminal, true) == {:ok, :confirmed}
      assert_received :terminal
    end

    test "a native failure falls back to an unconfirmed terminal request" do
      native = fn -> {:error, :clipboard_not_supported} end
      assert Clipboard.cascade(native, fn -> :ok end, false) == {:ok, :requested}
    end

    test "a remote session runs the terminal once, after the native attempt" do
      native = fn ->
        send(self(), :native)
        {:error, :clipboard_occupied}
      end

      terminal = fn ->
        send(self(), :terminal)
        :ok
      end

      assert Clipboard.cascade(native, terminal, true) == {:ok, :requested}
      # Native first, so a terminal write cannot race the selection ownership.
      assert Process.info(self(), :messages) == {:messages, [:native, :terminal]}
    end

    test "reports every failed attempt in order" do
      native = fn -> {:error, :clipboard_not_supported} end
      terminal = fn -> {:error, [tmux: :no_tmux_client, osc52: :enxio]} end

      assert Clipboard.cascade(native, terminal, false) ==
               {:error,
                {:copy_failed,
                 [native: :clipboard_not_supported, tmux: :no_tmux_client, osc52: :enxio]}}
    end

    test "without a terminal, a native failure is final" do
      assert Clipboard.cascade(fn -> {:error, :timeout} end, nil, true) ==
               {:error, {:copy_failed, [native: :timeout]}}
    end
  end

  describe "copy/2" do
    test "copies text natively and confirms it" do
      owner = owner(fn :set_text, [:handle, :clipboard, "hello"] -> :ok end)

      assert Clipboard.copy("hello", owner: owner, environment: @local, osc52_writer: writer()) ==
               {:ok, :confirmed}

      assert_received {:native, :set_text, [:handle, :clipboard, "hello"]}
      refute_received {:osc52, _sequence}
    end

    test "offers HTML with the text as its plain alternative" do
      owner = owner(fn :set_html, [:handle, :clipboard, "<b>hi</b>", "**hi**"] -> :ok end)

      assert Clipboard.copy("**hi**",
               html: "<b>hi</b>",
               owner: owner,
               environment: @local,
               osc52_writer: writer()
             ) == {:ok, :confirmed}

      assert_received {:native, :set_html, [:handle, :clipboard, "<b>hi</b>", "**hi**"]}
    end

    test "retries plain text natively when HTML is rejected" do
      owner =
        owner(fn
          :set_html, _args -> {:error, :conversion_failure}
          :set_text, [:handle, :primary, "hi"] -> :ok
        end)

      assert Clipboard.copy("hi",
               html: "<b>hi</b>",
               selection: :primary,
               owner: owner,
               environment: @local
             ) == {:ok, :confirmed}

      assert_received {:native, :set_html, _args}
      assert_received {:native, :set_text, [:handle, :primary, "hi"]}
    end

    test "does not retry plain text when the owner itself failed" do
      assert Clipboard.copy("hi",
               html: "<b>hi</b>",
               owner: :no_such_owner,
               terminal: :never,
               environment: @local
             ) == {:error, {:copy_failed, [native: :owner_not_running]}}
    end

    test "falls back to OSC 52 with the plain text when the native copy fails" do
      owner = owner(fn _function, _args -> {:error, :clipboard_not_supported} end)

      assert Clipboard.copy("hi",
               html: "<b>hi</b>",
               owner: owner,
               environment: @local,
               osc52_writer: writer()
             ) == {:ok, :requested}

      assert_received {:osc52, "\e]52;c;aGk=\a"}
    end

    test "forwards to the terminal over SSH even after a native success" do
      owner = owner(fn :set_text, _args -> :ok end)

      assert Clipboard.copy("hi", owner: owner, environment: @ssh, osc52_writer: writer()) ==
               {:ok, :confirmed}

      assert_received {:osc52, "\e]52;c;aGk=\a"}
    end

    test "terminal: :never stays native" do
      owner = owner(fn :set_text, _args -> {:error, :clipboard_not_supported} end)

      assert Clipboard.copy("hi",
               terminal: :never,
               owner: owner,
               environment: @ssh,
               osc52_writer: writer()
             ) == {:error, {:copy_failed, [native: :clipboard_not_supported]}}

      refute_received {:osc52, _sequence}
    end

    test "the primary selection never reaches the terminal" do
      owner = owner(fn :set_text, [:handle, :primary, "hi"] -> {:error, :clipboard_occupied} end)

      assert Clipboard.copy("hi",
               selection: :primary,
               owner: owner,
               environment: @ssh,
               osc52_writer: writer()
             ) == {:error, {:copy_failed, [native: :clipboard_occupied]}}

      refute_received {:osc52, _sequence}
    end

    test "rejects empty text and invalid UTF-8 without touching any clipboard" do
      owner = owner(fn function, _args -> flunk("unexpected native #{function}") end)
      opts = [owner: owner, environment: @ssh, osc52_writer: writer()]

      assert Clipboard.copy("", opts) == {:error, :empty}
      assert Clipboard.copy(<<0xFF, 0xFE>>, opts) == {:error, :invalid_utf8}
      refute_received {:native, _function, _args}
      refute_received {:osc52, _sequence}
    end

    test "rejects invalid options" do
      assert_raise ArgumentError, ~r/:selection/, fn ->
        Clipboard.copy("hi", selection: :other)
      end

      assert_raise ArgumentError, ~r/:terminal/, fn ->
        Clipboard.copy("hi", terminal: :sometimes, selection: :primary)
      end

      assert_raise ArgumentError, ~r/unknown keys/, fn -> Clipboard.copy("hi", colour: :red) end

      assert_raise ArgumentError, ~r/:html to be a non-empty string/, fn ->
        Clipboard.copy("hi", html: :bold)
      end

      assert_raise ArgumentError, ~r/:html to be valid UTF-8/, fn ->
        Clipboard.copy("hi", html: <<0xFF>>)
      end
    end

    test "a missing owner falls back to the terminal" do
      assert Clipboard.copy("hi",
               owner: :no_such_owner,
               environment: @local,
               osc52_writer: writer()
             ) == {:ok, :requested}

      assert_received {:osc52, _sequence}
    end
  end

  describe "native-only operations" do
    test "read text and HTML from the requested selection" do
      owner =
        owner(fn
          :get_text, [:handle, :primary] -> {:ok, "selected"}
          :get_html, [:handle, :clipboard] -> {:error, :content_not_available}
        end)

      assert Clipboard.read_text(owner: owner, selection: :primary) == {:ok, "selected"}
      assert Clipboard.read_html(owner: owner) == {:error, :content_not_available}
    end

    test "read an image as RGBA pixels" do
      rgba = :binary.copy(<<255, 0, 0, 255>>, 2)
      owner = owner(fn :get_image, [:handle, :clipboard] -> {:ok, {2, 1, rgba}} end)

      assert Clipboard.read_image(owner: owner) ==
               {:ok, %Image{width: 2, height: 1, rgba: rgba}}
    end

    test "copy a valid image and reject a mismatched buffer" do
      owner = owner(fn :set_image, [:handle, :clipboard, 1, 1, <<1, 2, 3, 4>>] -> :ok end)

      assert Clipboard.copy_image(%Image{width: 1, height: 1, rgba: <<1, 2, 3, 4>>}, owner: owner) ==
               :ok

      assert Clipboard.copy_image(%Image{width: 2, height: 1, rgba: <<1, 2, 3, 4>>}, owner: owner) ==
               {:error, :invalid_image}

      assert_received {:native, :set_image, _args}
      refute_received {:native, :set_image, _args}
    end

    test "clear the clipboard" do
      owner = owner(fn :clear, [:handle, :clipboard] -> :ok end)
      assert Clipboard.clear(owner: owner) == :ok
    end
  end
end
