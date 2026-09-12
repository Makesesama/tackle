defmodule Tackle.Tools.Edit do
  @moduledoc "Applies exact, targeted replacements to one text file."

  use Tackle.Lib.Tool

  alias Tackle.Tools.FileSystem

  tool_name("edit")

  description(
    "Edit one UTF-8 text file using exact replacements. Each edits[].oldText must occur exactly once " <>
      "in the original file, and replacements must not overlap. Paths may be relative to the current " <>
      "working directory or absolute."
  )

  input do
    field(:path, :string, required: true, description: "Path to the file to edit")

    field(:edits, {:list, :map},
      required: true,
      description: "One or more objects containing oldText and newText strings"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"path" => path, "edits" => edits}, context) do
    with {:ok, edits} <- validate_edits(edits),
         {:ok, absolute_path} <- FileSystem.resolve_path(path, context) do
      FileSystem.mutate(absolute_path, fn -> edit_file(absolute_path, path, edits) end)
    end
  end

  defp edit_file(absolute_path, display_path, edits) do
    with {:ok, content} <- read_utf8(absolute_path, display_path),
         {bom, content} <- strip_bom(content),
         line_ending <- detect_line_ending(content),
         normalized <- normalize_line_endings(content),
         normalized_edits <- normalize_edits(edits),
         {:ok, replacements} <- locate_replacements(normalized, normalized_edits, display_path),
         :ok <- reject_overlaps(replacements, display_path),
         edited <- apply_replacements(normalized, replacements),
         :ok <- reject_unchanged(normalized, edited, display_path),
         restored <- bom <> restore_line_endings(edited, line_ending),
         :ok <- write_content(absolute_path, display_path, restored) do
      {:ok, "Successfully replaced #{length(edits)} block(s) in #{display_path}."}
    end
  end

  defp validate_edits([]), do: {:error, "edits must contain at least one replacement"}

  defp validate_edits(edits) when is_list(edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, validated} ->
      case validate_edit(edit, index) do
        {:ok, edit} -> {:cont, {:ok, [edit | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_edits(_edits), do: {:error, "edits must be an array"}

  defp validate_edit(edit, index) when is_map(edit) do
    edit = stringify_edit_keys(edit)
    old_text = Map.get(edit, "oldText")
    new_text = Map.get(edit, "newText")

    cond do
      not is_binary(old_text) -> {:error, "edits[#{index}].oldText must be a string"}
      old_text == "" -> {:error, "edits[#{index}].oldText must not be empty"}
      not is_binary(new_text) -> {:error, "edits[#{index}].newText must be a string"}
      true -> {:ok, %{index: index, old_text: old_text, new_text: new_text}}
    end
  end

  defp validate_edit(_edit, index), do: {:error, "edits[#{index}] must be an object"}

  defp stringify_edit_keys(edit) do
    Map.new(edit, fn
      {:oldText, value} -> {"oldText", value}
      {:newText, value} -> {"newText", value}
      pair -> pair
    end)
  end

  defp read_utf8(absolute_path, display_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        if String.valid?(content),
          do: {:ok, content},
          else: {:error, "Could not edit #{display_path}: file is not valid UTF-8"}

      {:error, reason} ->
        {:error, "Could not edit #{FileSystem.format_error(display_path, reason)}"}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, content::binary>>), do: {<<0xEF, 0xBB, 0xBF>>, content}
  defp strip_bom(content), do: {"", content}

  defp detect_line_ending(content) do
    case :binary.match(content, "\n") do
      {index, 1} when index > 0 ->
        if :binary.at(content, index - 1) == ?\r, do: :crlf, else: :lf

      _ ->
        :lf
    end
  end

  defp normalize_line_endings(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp normalize_edits(edits) do
    Enum.map(edits, fn edit ->
      %{
        edit
        | old_text: normalize_line_endings(edit.old_text),
          new_text: normalize_line_endings(edit.new_text)
      }
    end)
  end

  defp locate_replacements(content, edits, display_path) do
    edits
    |> Enum.reduce_while({:ok, []}, fn edit, {:ok, replacements} ->
      case :binary.matches(content, edit.old_text) do
        [] ->
          {:halt,
           {:error,
            "Could not find edits[#{edit.index}].oldText in #{display_path}; it must match exactly"}}

        [{start, length}] ->
          replacement = Map.merge(edit, %{start: start, length: length})
          {:cont, {:ok, [replacement | replacements]}}

        matches ->
          {:halt,
           {:error,
            "Found #{length(matches)} occurrences of edits[#{edit.index}].oldText in #{display_path}; " <>
              "include more context so it is unique"}}
      end
    end)
    |> case do
      {:ok, replacements} -> {:ok, Enum.sort_by(replacements, & &1.start)}
      error -> error
    end
  end

  defp reject_overlaps(replacements, display_path) do
    replacements
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [left, right] -> left.start + left.length > right.start end)
    |> case do
      nil ->
        :ok

      [left, right] ->
        {:error,
         "edits[#{left.index}] and edits[#{right.index}] overlap in #{display_path}; merge them into one edit"}
    end
  end

  defp apply_replacements(content, replacements) do
    replacements
    |> Enum.reverse()
    |> Enum.reduce(content, fn replacement, result ->
      prefix = binary_part(result, 0, replacement.start)
      suffix_start = replacement.start + replacement.length
      suffix = binary_part(result, suffix_start, byte_size(result) - suffix_start)
      prefix <> replacement.new_text <> suffix
    end)
  end

  defp reject_unchanged(content, content, display_path),
    do: {:error, "No changes made to #{display_path}; replacements produced identical content"}

  defp reject_unchanged(_content, _edited, _display_path), do: :ok

  defp restore_line_endings(content, :crlf), do: String.replace(content, "\n", "\r\n")
  defp restore_line_endings(content, :lf), do: content

  defp write_content(absolute_path, display_path, content) do
    case File.write(absolute_path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Could not edit #{FileSystem.format_error(display_path, reason)}"}
    end
  end
end
