defmodule Tackle.Lib.Tool.Content do
  @moduledoc """
  A tool result that pairs a text projection with provider-neutral content parts.

  Most tools return a string, or a map/list that is JSON-encoded into one. Tools
  that also produce non-text content (currently images) return this struct from
  `Tackle.Lib.Tool`'s `execute/2` instead:

      def run(%{"path" => path}, _context) do
        {:ok,
         Tackle.Lib.Tool.Content.new(
           "Read image \#{path} (image/png, 1.2MB).",
           [Tackle.Lib.Tool.Content.image("image/png", base64_data)]
         )}
      end

  `Tackle.Lib.Tool.settle/3` projects `:text` into the transcript's string
  projection — what human-facing surfaces and token estimates use — and keeps
  `:parts` as structured content that provider adapters lower into their wire
  format. Parts are additive: a tool that only needs text keeps returning a
  string.

  ## Part shapes

  Parts are plain maps with **string keys** so they survive the durable session
  codec unchanged:

    * text — `%{"type" => "text", "text" => String.t()}`
    * image — `%{"type" => "image", "media_type" => String.t(), "data" => String.t()}`,
      where `"data"` is standard base64 without a data-URL prefix

  Text is already carried by the `:text` field, so `:parts` holds only the extra,
  non-text parts. Adapters that cannot send a part type must degrade explicitly
  (for example, by substituting a note) rather than dropping it silently.
  """

  @typedoc "A provider-neutral content part."
  @type part :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{text: String.t(), parts: [part()]}

  @enforce_keys [:text, :parts]
  defstruct [:text, :parts]

  @doc """
  Builds tool content from a text projection and extra content parts.
  """
  @spec new(String.t(), [part()]) :: t()
  def new(text, parts) when is_binary(text) and is_list(parts) do
    %__MODULE__{text: text, parts: parts}
  end

  @doc "Builds a text content part."
  @spec text(String.t()) :: part()
  def text(text) when is_binary(text), do: %{"type" => "text", "text" => text}

  @doc """
  Builds an image content part from standard base64 data.

  `media_type` is the IANA image media type (for example `"image/png"`).
  """
  @spec image(String.t(), String.t()) :: part()
  def image(media_type, base64_data)
      when is_binary(media_type) and is_binary(base64_data) do
    %{"type" => "image", "media_type" => media_type, "data" => base64_data}
  end

  @doc """
  Validates a list of content parts.

  Returns `:ok` or `{:error, reason}` with a human-readable reason that names
  the offending part.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(parts) when is_list(parts), do: validate_parts(parts, 1)

  def validate(other), do: {:error, "content parts must be a list, got: #{inspect(other)}"}

  defp validate_parts([], _index), do: :ok

  defp validate_parts([part | rest], index) do
    case validate_part(part) do
      :ok -> validate_parts(rest, index + 1)
      {:error, reason} -> {:error, "content part #{index} #{reason}"}
    end
  end

  defp validate_part(%{"type" => "text", "text" => text}) when is_binary(text), do: :ok

  defp validate_part(%{"type" => "image", "media_type" => media_type, "data" => data})
       when is_binary(media_type) and is_binary(data) do
    if String.starts_with?(media_type, "image/") do
      :ok
    else
      {:error, "must use an image/* media type, got: #{inspect(media_type)}"}
    end
  end

  defp validate_part(%{"type" => "text"}),
    do: {:error, ~s(must carry a string "text")}

  defp validate_part(%{"type" => "image"}),
    do: {:error, ~s(must carry string "media_type" and base64 string "data")}

  defp validate_part(%{"type" => type}),
    do: {:error, "has unsupported type #{inspect(type)}"}

  defp validate_part(other),
    do: {:error, ~s(must be a map with a "type" key, got: #{inspect(other)})}
end
