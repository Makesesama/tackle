defmodule Clipboard.NativeTest do
  use ExUnit.Case, async: false

  alias Clipboard.{Image, Native, Owner}

  test "the NIF loads and opening a handle returns a result tuple" do
    # Without a display server this is an error; with one it is a handle.
    # Opening a handle does not change the clipboard either way.
    case Native.new() do
      {:ok, handle} -> assert is_reference(handle)
      {:error, reason} -> assert is_atom(reason) or match?({:unknown, _}, reason)
    end
  end

  describe "against the system clipboard" do
    @describetag :system_clipboard

    setup do
      %{owner: start_supervised!({Owner, name: nil})}
    end

    test "round-trips text natively", %{owner: owner} do
      text = "clipboard_ex #{System.unique_integer([:positive])} ✓"

      assert Clipboard.copy(text, owner: owner, terminal: :never) == {:ok, :confirmed}
      assert Clipboard.read_text(owner: owner) == {:ok, text}
    end

    test "round-trips an RGBA image natively", %{owner: owner} do
      image = %Image{width: 2, height: 2, rgba: :binary.copy(<<0, 128, 255, 255>>, 4)}

      assert Clipboard.copy_image(image, owner: owner) == :ok
      assert Clipboard.read_image(owner: owner) == {:ok, image}
    end
  end
end
