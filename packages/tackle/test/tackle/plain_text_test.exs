defmodule Tackle.PlainTextTest do
  use ExUnit.Case, async: true

  alias Tackle.PlainText

  describe "clean/1" do
    test "strips CSI, OSC, and two-character escape sequences" do
      assert PlainText.clean("\e[31mred\e[0m \e]0;title\a\e]8;;url\e\\link") == "red link"
      assert PlainText.clean("\e7saved\e8 \e(Bascii \eMup \e=keypad") == "saved ascii up keypad"
    end

    test "strips control characters but keeps tabs and newlines" do
      assert PlainText.clean("a\0b\bc\ad\e\x7Fe\u0085f\tg\nh") == "abcdef\tg\nh"
    end

    test "keeps what a terminal shows after carriage-return redraws" do
      assert PlainText.clean(" 10%\r 50%\r100%\r\ndone\r") == "100%\ndone"
    end

    test "drops invalid UTF-8" do
      assert PlainText.clean("ok" <> <<0xFF, 0xC3>> <> "ü") == "okü"
    end
  end

  test "truncate/2 cuts on characters" do
    assert PlainText.truncate("üüü", 3) == "üüü"
    assert PlainText.truncate("üüüü", 2) == "üü…"
  end

  test "truncate_bytes/2 never splits a character" do
    assert PlainText.truncate_bytes("üü", 4) == "üü"
    assert PlainText.truncate_bytes("üüü", 5) == "ü…"
    assert PlainText.truncate_bytes("üüü", 4) == "…"
    assert PlainText.truncate_bytes("üüü", 3) == "…"
    assert PlainText.truncate_bytes("üüü", 2) == "ü"
    assert PlainText.truncate_bytes("üüü", 1) == ""
    assert PlainText.truncate_bytes("abcdef", 4) == "a…"

    for text <- ["abcdef", "üüüü", "aüb€c"], bytes <- 0..12 do
      assert byte_size(PlainText.truncate_bytes(text, bytes)) <= bytes
    end
  end

  test "last_chars/2 keeps the end on characters" do
    assert PlainText.last_chars("abc", 5) == "abc"
    assert PlainText.last_chars("aüüü", 2) == "üü"
  end

  test "last_bytes/2 never starts inside a character" do
    assert PlainText.last_bytes("abc", 5) == "abc"
    assert PlainText.last_bytes("aüüü", 3) == "ü"
    assert String.valid?(PlainText.last_bytes(String.duplicate("ü", 100), 51))
  end
end
