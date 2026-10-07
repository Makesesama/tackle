# clipboard_ex

Native system clipboard access for Elixir, backed by Rust's
[`arboard`](https://github.com/1Password/arboard) through a Rustler NIF, with
tmux and OSC 52 terminal fallbacks.

The package and OTP application are `:clipboard_ex`; the modules live under
`Clipboard`.

> Status: experimental; the API may change. The Tackle CLI uses it for
> copying and for image/text pasting.

## Usage

```elixir
{:ok, :confirmed} = Clipboard.copy("hello")
{:ok, "hello"} = Clipboard.read_text()

# Rich-text targets paste the HTML, everything else the plain text.
Clipboard.copy("**hi**", html: "<p><strong>hi</strong></p>")

# Linux PRIMARY selection (middle-click paste). Never forwarded to a terminal.
Clipboard.copy("selected", selection: :primary)

# Images are raw RGBA pixels; PNG encoding is up to the caller.
{:ok, %Clipboard.Image{width: w, height: h, rgba: pixels}} = Clipboard.read_image()
:ok = Clipboard.copy_image(%Clipboard.Image{width: 1, height: 1, rgba: <<255, 0, 0, 255>>})
```

### Copy results

`Clipboard.copy/2` mirrors the OpenAI Codex TUI's clipboard order:

1. Copy through the native clipboard.
2. Reach the user's terminal when the native copy fails, or always inside tmux
   or over SSH, where the native clipboard may belong to another machine:
   - inside tmux, `tmux load-buffer -w` to the most recently active client
     (when `set-clipboard` is not `off` and the terminal supports OSC 52);
   - otherwise, or when tmux forwarding fails, an OSC 52 escape sequence
     written to `/dev/tty` (falling back to stdout), wrapped for tmux
     passthrough inside tmux. Payloads above 100,000 bytes are refused.

The result says how certain the copy is:

| Result | Meaning |
|---|---|
| `{:ok, :confirmed}` | The native clipboard accepted the text. |
| `{:ok, :requested}` | Only the terminal was asked. Terminals never acknowledge OSC 52, so the copy may not have happened. |
| `{:error, {:copy_failed, attempts}}` | Every transport failed; `attempts` lists `{transport, reason}` in order. |
| `{:error, :empty}` / `{:error, :invalid_utf8}` | Rejected before touching any clipboard. |

Pass `terminal: :never` for native only, or `osc52_writer: fun` to deliver the
OSC 52 sequence through output you own (for example a TUI's terminal handle).
When the native clipboard rejects `:html`, the plain text alone is retried
before any terminal fallback.

Copies may run inside untrusted project directories, so `tmux`, `sh`, and
`head` are never resolved through `PATH`: only system and package-manager
directories are searched, and child processes get a `PATH` of those alone
(see `Clipboard.Terminal`). A tmux installed elsewhere is skipped in favour of
OSC 52.

## Clipboard ownership

On X11 and Wayland, the copying process serves the clipboard contents
whenever another application pastes; if it drops its clipboard handle, the
contents can vanish. `Clipboard.Owner`, started with the application, keeps a
single native handle alive and serialises native calls. It opens the handle on
first use and retries after failures such as an unreachable display server.

On shutdown the owner closes the handle on a dirty scheduler, which on X11
offers the contents to a running clipboard manager (waiting up to a few
seconds). Without a clipboard manager, copied contents survive only while the
VM runs. A killed owner or `System.halt/1` skips that handover.

An open handle is kept even if the display server later goes away; restart
the owner to reconnect.

## Platform notes

- **Linux:** Wayland through the `ext-data-control`/`wlr-data-control`
  protocols when the compositor offers them, otherwise X11 or XWayland. The
  Rust crates speak the protocols directly, so no system libraries are linked.
  On Wayland, `:secondary` (and `:primary` without compositor support)
  returns `{:error, :clipboard_not_supported}`.
- **macOS and Windows:** only the `:clipboard` selection exists; `:primary`
  and `:secondary` return `{:error, :unsupported_selection}`.
- Native calls run on dirty I/O schedulers. A call that exceeds `:timeout`
  (default 5000 ms) returns `{:error, :timeout}`; the native call itself runs
  to completion.

## Not included

- No WSL fallback (`powershell.exe Set-Clipboard`) and no markdown-to-HTML
  rendering; pass HTML yourself.
- Not packaged with `rustler_precompiled`, and not yet wired into Nix or
  Burrito builds: building needs a Rust toolchain.
- Only verified on Linux without a display server so far; macOS and Windows
  compile paths follow arboard's platform split but are untested.
- The Hex package `clipboard` also defines a `Clipboard` module, so the two
  cannot be loaded together.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted

# Reads and overwrites the real clipboard of the current desktop session.
mix test --include system_clipboard

# Native crate
(cd native/clipboard_ex && cargo fmt --check && cargo clippy)
```

Default tests use a fake native module, an injected OSC 52 writer, and a fake
`tmux` script; they never change a clipboard or write to the terminal. One
test opens a native handle to check that the NIF loads, which connects to the
display server when there is one.
