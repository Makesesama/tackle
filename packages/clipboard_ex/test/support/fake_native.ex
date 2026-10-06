defmodule Clipboard.FakeNative do
  @moduledoc false
  # Stands in for `Clipboard.Native` in owner-backed tests. Each call is
  # reported to the test process and answered by a responder function, both
  # registered with `setup/2`. Tests using it must not run async.

  @key __MODULE__

  def setup(test_pid, responder) do
    :persistent_term.put(@key, {test_pid, responder})
  end

  def teardown, do: :persistent_term.erase(@key)

  def new, do: reply(:new, [])
  def set_text(handle, selection, text), do: reply(:set_text, [handle, selection, text])

  def set_html(handle, selection, html, alt_text),
    do: reply(:set_html, [handle, selection, html, alt_text])

  def get_text(handle, selection), do: reply(:get_text, [handle, selection])
  def get_html(handle, selection), do: reply(:get_html, [handle, selection])

  def set_image(handle, selection, width, height, rgba),
    do: reply(:set_image, [handle, selection, width, height, rgba])

  def get_image(handle, selection), do: reply(:get_image, [handle, selection])
  def clear(handle, selection), do: reply(:clear, [handle, selection])
  def close(handle), do: reply(:close, [handle])

  defp reply(function, args) do
    {test_pid, responder} = :persistent_term.get(@key)
    send(test_pid, {:native, function, args})
    responder.(function, args)
  end
end
