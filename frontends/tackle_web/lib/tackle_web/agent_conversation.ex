defmodule Tackle.Web.AgentConversation do
  @moduledoc """
  Durable transcript for one pull request's conversation with the assistant.

  `Tackle.Phoenix.Runner` keeps a conversation in memory and stops after thirty
  minutes idle, so the transcript has to outlive it. It is written whenever a
  turn settles and read back when a Runner is started, which is what makes a
  question survive a page reload or a redeploy.

  Messages are encoded with `Tackle.Session.Codec`, the harness's durable codec,
  rather than as an ad-hoc map. That keeps tool calls, content parts and provider
  continuation state intact, so a restored conversation continues where it left
  off instead of degrading into plain text.

  Alongside the messages it stores where each question was asked. A question is
  asked *about a line*, and the answer belongs under that line, so the anchor is
  part of the conversation rather than a detail of the browser tab that asked it.
  Anchors are keyed by the id of the question message they belong to.

  As with the review state, the directory is created on demand and writing is
  atomic: a reader never sees a half-written file. A missing or corrupt file
  reads as an empty conversation rather than raising, because losing a transcript
  must not take down the page.
  """

  require Logger

  alias Tackle.Lib.Message
  alias Tackle.Session.Codec
  alias Tackle.Web.Paths
  alias Tackle.Web.Review

  @version 1

  @typedoc """
  Where a question was asked: a file, one side of the diff, and a line.

  The same shape the review comments are anchored to, so the diff component looks
  up comments and assistant threads with one key. `:general` means the question
  was about the pull request as a whole rather than a line.
  """
  @type anchor :: {String.t(), :new | :old, pos_integer()} | :general

  @typedoc "A stored conversation: the messages and the anchor of each question."
  @type transcript :: %{
          messages: [Message.t()],
          anchors: %{optional(String.t()) => anchor() | :general}
        }

  @doc """
  Identity of a pull request's conversation.

  Doubles as the `user_id` handed to `Tackle.Phoenix.Runner`, which keys one
  Runner per value.
  """
  @spec key(String.t(), String.t(), pos_integer()) :: String.t()
  def key(owner, name, number) when is_binary(owner) and is_binary(name) do
    "#{owner}/#{name}##{number}"
  end

  @doc """
  File holding a pull request's transcript.

  Named with `Tackle.Web.Review.file_name/3` so the transcript and the review of
  the same pull request always agree on their names; only the directory differs.
  """
  @spec path(String.t(), String.t(), pos_integer()) :: Path.t()
  def path(owner, name, number) do
    Path.join(Paths.conversations_root(), Review.file_name(owner, name, number))
  end

  @doc """
  Reads the stored transcript, oldest message first.

  Returns an empty conversation when nothing was stored, when the file cannot be
  read, or when it is not a transcript this module wrote.
  """
  @spec load(Path.t()) :: transcript()
  def load(path) do
    case File.read(path) do
      {:ok, body} ->
        parse(body, path)

      {:error, :enoent} ->
        empty()

      {:error, reason} ->
        warn(path, "could not read it: #{inspect(reason)}")
        empty()
    end
  end

  @doc """
  Writes the transcript, replacing any previous one.

  Encoding is best effort per message: a message the codec refuses (one holding
  a value that cannot be reconstructed) is dropped with a warning rather than
  failing the whole write, so the rest of the conversation still survives.
  """
  @spec save(Path.t(), [Message.t()], %{optional(String.t()) => term()}) :: :ok | {:error, term()}
  def save(path, messages, anchors \\ %{}) when is_list(messages) do
    body =
      JSON.encode!(%{
        "version" => @version,
        "messages" => Enum.flat_map(messages, &encode_message/1),
        "anchors" => encode_anchors(anchors)
      })

    write(path, body)
  end

  @doc "An empty conversation."
  @spec empty() :: transcript()
  def empty, do: %{messages: [], anchors: %{}}

  defp encode_message(%Message{} = message) do
    case Codec.encode_message(message) do
      {:ok, data} -> [data]
      {:error, reason} -> drop(message, reason)
    end
  end

  defp decode_message(data) when is_map(data) do
    case Codec.decode_message(data) do
      {:ok, %Message{} = message} -> [message]
      {:error, reason} -> drop(data, reason)
    end
  rescue
    # The codec is documented to reject unusable messages with `{:error, _}`,
    # but a transcript is not worth failing a page load over: decode defensively
    # so a message that makes the codec raise costs one message, not the review.
    error -> drop(data, error)
  end

  defp decode_message(_data), do: []

  defp parse(body, path) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        %{
          messages: Enum.flat_map(messages_of(decoded), &decode_message/1),
          anchors: decode_anchors(Map.get(decoded, "anchors", %{}))
        }

      {:ok, other} ->
        warn(path, "unrecognized transcript #{inspect(other, limit: 5)}")
        empty()

      {:error, reason} ->
        warn(path, "not valid JSON: #{inspect(reason)}")
        empty()
    end
  end

  defp messages_of(decoded) do
    case Map.get(decoded, "messages") do
      messages when is_list(messages) -> messages
      _other -> []
    end
  end

  defp decode_anchors(anchors) when is_map(anchors) do
    for {id, anchor} <- anchors, is_binary(id), keep = decode_anchor(anchor), into: %{} do
      {id, keep}
    end
  end

  defp decode_anchors(_anchors), do: %{}

  defp decode_anchor(:general), do: :general
  defp decode_anchor("general"), do: :general

  defp decode_anchor(%{"path" => path, "side" => side, "line" => line})
       when is_binary(path) and is_integer(line) and line > 0 do
    case side do
      "new" -> {path, :new, line}
      "old" -> {path, :old, line}
      _other -> nil
    end
  end

  defp decode_anchor(_anchor), do: nil

  defp encode_anchors(anchors) when is_map(anchors) do
    for {id, anchor} <- anchors, is_binary(id), encoded = encode_anchor(anchor), into: %{} do
      {id, encoded}
    end
  end

  defp encode_anchor(:general), do: "general"

  defp encode_anchor({path, side, line})
       when is_binary(path) and side in [:new, :old] and is_integer(line) and line > 0 do
    %{"path" => path, "side" => Atom.to_string(side), "line" => line}
  end

  defp encode_anchor(_anchor), do: nil

  defp write(path, body) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

      case File.write(temporary, body) do
        :ok ->
          case File.rename(temporary, path) do
            :ok ->
              :ok

            {:error, reason} ->
              File.rm(temporary)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp drop(value, reason) do
    Logger.warning(
      "Dropping a message that cannot be stored durably: #{inspect(reason)} " <>
        "(#{inspect(value, limit: 3)})"
    )

    []
  end

  defp warn(path, detail) do
    Logger.warning("Ignoring the assistant transcript at #{path}: #{detail}")
  end
end
