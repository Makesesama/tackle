defmodule Clipboard.TerminalTest do
  use ExUnit.Case, async: true

  alias Clipboard.{Environment, Terminal}

  @local %Environment{}
  @tmux %Environment{tmux: true, tmux_pane: "%1"}

  describe "osc52/2" do
    test "encodes text as base64 in an OSC 52 sequence" do
      assert Terminal.osc52("hello") == {:ok, "\e]52;c;aGVsbG8=\a"}
    end

    test "wraps the sequence in tmux passthrough" do
      assert Terminal.osc52("hello", true) == {:ok, "\ePtmux;\e\e]52;c;aGVsbG8=\a\e\\"}
    end

    test "refuses payloads above the limit" do
      limit = Terminal.max_bytes()
      assert {:ok, _sequence} = Terminal.osc52(String.duplicate("a", limit))

      assert Terminal.osc52(String.duplicate("a", limit + 1)) ==
               {:error, {:too_large, limit + 1}}
    end
  end

  describe "copy/3" do
    test "writes OSC 52 outside tmux" do
      writer = fn sequence ->
        send(self(), {:wrote, sequence})
        :ok
      end

      tmux = fn _text, _pane -> flunk("tmux must not be used outside tmux") end

      assert Terminal.copy("hi", @local, writer: writer, tmux: tmux) == :ok
      assert_received {:wrote, "\e]52;c;aGk=\a"}
    end

    test "prefers tmux forwarding inside tmux" do
      writer = fn _sequence -> flunk("OSC 52 must not be written when tmux succeeds") end

      tmux = fn text, pane ->
        send(self(), {:tmux, text, pane})
        :ok
      end

      assert Terminal.copy("hi", @tmux, writer: writer, tmux: tmux) == :ok
      assert_received {:tmux, "hi", "%1"}
    end

    test "falls back to wrapped OSC 52 when tmux forwarding fails" do
      writer = fn sequence ->
        send(self(), {:wrote, sequence})
        :ok
      end

      tmux = fn _text, _pane -> {:error, :tmux_clipboard_disabled} end

      assert Terminal.copy("hi", @tmux, writer: writer, tmux: tmux) == :ok
      assert_received {:wrote, "\ePtmux;" <> _rest}
    end

    test "reports every failed transport" do
      writer = fn _sequence -> {:error, :enospc} end
      tmux = fn _text, _pane -> {:error, :no_tmux_client} end

      assert Terminal.copy("hi", @tmux, writer: writer, tmux: tmux) ==
               {:error, [tmux: :no_tmux_client, osc52: :enospc]}

      assert Terminal.copy("hi", @local, writer: writer) == {:error, [osc52: :enospc]}
    end

    test "does not hand oversized payloads to tmux" do
      text = String.duplicate("a", Terminal.max_bytes() + 1)
      tmux = fn _text, _pane -> flunk("oversized payloads must not reach tmux") end
      writer = fn _sequence -> flunk("oversized payloads must not be written") end

      assert Terminal.copy(text, @tmux, writer: writer, tmux: tmux) ==
               {:error,
                [tmux: {:too_large, byte_size(text)}, osc52: {:too_large, byte_size(text)}]}
    end
  end

  describe "choose_client/3" do
    @capable "Ms: (string) \\E]52;%p1%s;%p2%s\\007\n"

    test "picks the most recently active client with OSC 52 support" do
      clients = "100 /dev/pts/1\n300 /dev/pts/2\n200 /dev/pts/3\n"

      messages = fn client ->
        send(self(), {:messages, client})
        {:ok, @capable}
      end

      assert Terminal.choose_client(fn -> {:ok, "on\n"} end, fn -> {:ok, clients} end, messages) ==
               {:ok, "/dev/pts/2"}

      assert_received {:messages, "/dev/pts/2"}
    end

    test "refuses when set-clipboard is off" do
      assert Terminal.choose_client(
               fn -> {:ok, "off\n"} end,
               fn -> flunk("clients must not be listed") end,
               fn _client -> flunk("capabilities must not be read") end
             ) == {:error, :tmux_clipboard_disabled}
    end

    test "refuses without an attached client" do
      assert Terminal.choose_client(
               fn -> {:ok, "external"} end,
               fn -> {:ok, "garbage\n\n"} end,
               fn _client -> flunk("capabilities must not be read") end
             ) == {:error, :no_tmux_client}
    end

    test "refuses a client whose terminal lacks the Ms capability" do
      assert Terminal.choose_client(
               fn -> {:ok, "on"} end,
               fn -> {:ok, "1 /dev/pts/1"} end,
               fn _client -> {:ok, "Ms: (string) \nTc: (flag) true\n"} end
             ) == {:error, :tmux_client_lacks_osc52}
    end

    test "propagates tmux command failures" do
      assert Terminal.choose_client(
               fn -> {:error, {:tmux_failed, 1}} end,
               fn -> flunk("clients must not be listed") end,
               fn _client -> flunk("capabilities must not be read") end
             ) == {:error, {:tmux_failed, 1}}
    end

    test "accepts CRLF output and ignores signed activity values" do
      assert Terminal.choose_client(
               fn -> {:ok, "on\r\n"} end,
               fn -> {:ok, "+900 /dev/pts/8\r\n-5 /dev/pts/7\r\n3 /dev/pts/2\r\n"} end,
               fn "/dev/pts/2" -> {:ok, "Ms: (string) x\r\n"} end
             ) == {:ok, "/dev/pts/2"}
    end
  end

  describe "trusted_directories/1" do
    test "never includes PATH or the working directory" do
      directories = Terminal.trusted_directories(%{"PATH" => "/tmp/evil:.", "USER" => "ada"})

      assert "/usr/bin" in directories
      assert "/etc/profiles/per-user/ada/bin" in directories
      refute "/tmp/evil" in directories
      refute "." in directories
    end

    test "ignores a USER that could escape the per-user profiles" do
      directories = Terminal.trusted_directories(%{"USER" => "../../tmp/evil"})
      refute Enum.any?(directories, &String.contains?(&1, "evil"))
    end
  end

  describe "tmux_copy/3 with a fake tmux" do
    setup do
      directory =
        Path.join(System.tmp_dir!(), "clipboard_ex_tmux_#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      # The fake needs `sh`, `head`, `cat`, and `sleep`; take them from the
      # test environment's PATH after the fake's own directory.
      path = System.get_env("PATH", "") |> String.split(":", trim: true)
      %{directory: directory, directories: [directory, "/bin" | path]}
    end

    test "loads the exact payload for the most active capable client", context do
      fake_tmux(context.directory,
        load_buffer: ~s(printf '%s' "$*" > "$DIR/args"; cat > "$DIR/out")
      )

      text = "multi\nline ✓ " <> String.duplicate("x", 70_000)

      assert Terminal.tmux_copy(text, "%1", directories: context.directories) == :ok
      assert File.read!(Path.join(context.directory, "out")) == text
      assert File.read!(Path.join(context.directory, "args")) == "load-buffer -w -t /dev/pts/7 -"
    end

    test "reports a failing load-buffer", context do
      fake_tmux(context.directory, load_buffer: "cat > /dev/null; echo oops >&2; exit 3")

      assert Terminal.tmux_copy("hi", "%1", directories: context.directories) ==
               {:error, {:tmux_failed, 3}}
    end

    test "survives tmux exiting before it reads the payload", context do
      fake_tmux(context.directory, load_buffer: "exit 4")
      text = String.duplicate("x", Terminal.max_bytes())

      assert {:error, {:tmux_failed, _reason}} =
               Terminal.tmux_copy(text, "%1", directories: context.directories)
    end

    test "gives up on a hung tmux", context do
      fake_tmux(context.directory, load_buffer: "exec sleep 5")

      assert Terminal.tmux_copy("hi", "%1", directories: context.directories, timeout: 200) ==
               {:error, :tmux_timeout}
    end

    test "respects a disabled set-clipboard", context do
      fake_tmux(context.directory, set_clipboard: "off", load_buffer: "exit 0")

      assert Terminal.tmux_copy("hi", "%1", directories: context.directories) ==
               {:error, :tmux_clipboard_disabled}
    end

    test "does not find tmux outside the trusted directories", context do
      assert Terminal.tmux_copy("hi", "%1", directories: [context.directory, "/bin"]) ==
               {:error, {:executable_not_found, "tmux"}}
    end
  end

  defp fake_tmux(directory, opts) do
    path = Path.join(directory, "tmux")

    File.write!(path, """
    #!/bin/sh
    DIR='#{directory}'
    case "$1" in
      show-options) echo '#{Keyword.get(opts, :set_clipboard, "external")}' ;;
      display-message) echo '$1' ;;
      list-clients) printf '3 /dev/pts/3\\n7 /dev/pts/7\\n' ;;
      show-messages) echo 'Ms: (string) \\E]52;%p1%s;%p2%s\\007' ;;
      load-buffer) #{Keyword.fetch!(opts, :load_buffer)} ;;
      *) exit 64 ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end

  test "tmux_copy/2 needs a pane" do
    assert Terminal.tmux_copy("hi", nil) == {:error, :no_tmux_pane}
  end
end
