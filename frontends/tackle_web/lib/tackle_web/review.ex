defmodule Tackle.Web.Review do
  @moduledoc """
  Review state for one pull request: the files a reviewer has marked as seen and
  the comments left on specific lines.

  This module owns the shape and the JSON round trip; `Tackle.Web.ReviewStore`
  owns the process and the durability. Comments are anchored to
  `{path, side, line}` rather than to a diff hunk offset, so they stay on the
  line they were written about even when the pull request head moves and the
  hunks are renumbered.
  """

  @version 1

  @typedoc "Which side of the diff a line number refers to."
  @type side :: :new | :old

  @type comment :: %{
          id: String.t(),
          path: String.t(),
          side: side(),
          line: pos_integer(),
          body: String.t(),
          author: String.t(),
          inserted_at: DateTime.t()
        }

  @type t :: %{viewed: MapSet.t(String.t()), comments: [comment()]}

  @doc "Review state for a pull request nobody has reviewed yet."
  @spec new() :: t()
  def new, do: %{viewed: MapSet.new(), comments: []}

  @doc """
  Builds the anchor of a comment, which is also its rendering position.
  """
  @spec anchor(comment() | map()) :: {String.t(), side(), pos_integer()}
  def anchor(%{path: path, side: side, line: line}), do: {path, side, line}

  @doc """
  Groups a file's comments by the line they are anchored to.
  """
  @spec comments_by_line(t(), String.t()) :: %{{side(), pos_integer()} => [comment()]}
  def comments_by_line(%{comments: comments}, path) do
    comments
    |> Enum.filter(&(&1.path == path))
    |> Enum.group_by(&{&1.side, &1.line})
  end

  @doc """
  File name a review is persisted under.

  Keyed by the project's slug and the review id the source chose, so a GitHub
  pull request and a local ref range are stored the same way. A slug never
  contains an underscore and a review id never contains one either — a pull
  request is `pr-<number>` and a ref range has git's own character rules — so
  the two halves cannot be confused for one another.
  """
  @spec file_name(String.t(), String.t()) :: String.t()
  def file_name(slug, review_id) do
    "#{slug}__#{review_id}.json"
  end

  @doc "Serializes a review for the on-disk cache."
  @spec to_json(t()) :: map()
  def to_json(%{viewed: viewed, comments: comments}) do
    %{
      "version" => @version,
      "viewed" => viewed |> MapSet.to_list() |> Enum.sort(),
      "comments" => Enum.map(comments, &comment_to_json/1)
    }
  end

  @doc """
  Parses persisted review state.

  Anything unrecognized yields a fresh review rather than an error: losing the
  ability to read the file is no reason to refuse to open the pull request.
  """
  @spec from_json(term()) :: t()
  def from_json(%{"comments" => comments} = stored) when is_list(comments) do
    %{
      viewed: stored |> Map.get("viewed", []) |> viewed_from_json(),
      comments: comments |> Enum.map(&comment_from_json/1) |> Enum.reject(&is_nil/1)
    }
  end

  def from_json(_unrecognized), do: new()

  defp viewed_from_json(list) when is_list(list) do
    list |> Enum.filter(&is_binary/1) |> MapSet.new()
  end

  defp viewed_from_json(_other), do: MapSet.new()

  defp comment_to_json(comment) do
    %{
      "id" => comment.id,
      "path" => comment.path,
      "side" => Atom.to_string(comment.side),
      "line" => comment.line,
      "body" => comment.body,
      "author" => comment.author,
      "inserted_at" => DateTime.to_iso8601(comment.inserted_at)
    }
  end

  defp comment_from_json(%{"id" => id, "path" => path, "line" => line, "body" => body} = stored)
       when is_binary(id) and is_binary(path) and is_integer(line) and is_binary(body) do
    case side_from_json(stored["side"]) do
      nil ->
        nil

      side ->
        %{
          id: id,
          path: path,
          side: side,
          line: line,
          body: body,
          author: stored["author"] || "reviewer",
          inserted_at: datetime_from_json(stored["inserted_at"])
        }
    end
  end

  defp comment_from_json(_malformed), do: nil

  defp side_from_json("new"), do: :new
  defp side_from_json("old"), do: :old
  defp side_from_json(_other), do: nil

  defp datetime_from_json(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp datetime_from_json(_other), do: DateTime.utc_now()
end
