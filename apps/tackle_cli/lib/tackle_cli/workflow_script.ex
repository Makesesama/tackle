defmodule Tackle.CLI.WorkflowScript do
  @moduledoc """
  Best-effort, display-only outline of a `run_workflow` Lua script.

  Frontends summarize a workflow by the profiles it names and whether it fans
  out, without evaluating it. The outline comes from a static scan of literal
  `tackle.spawn("profile", ...)` calls and, in scripts that call
  `tackle.parallel`, of the literal `return "profile", ...` statements its
  callbacks use. Profiles chosen at run time are not visible here, so the
  outline is a presentation hint — never an authorization or a prediction of
  what the workflow will do.
  """

  @spawn ~r/tackle\.spawn\s*\(\s*(["'])([^"'\n]+?)\1/
  @parallel ~r/tackle\.parallel\s*\(/
  @parallel_return ~r/\breturn\s+(["'])([^"'\n]+?)\1\s*,/
  @block_comment ~r/--\[(=*)\[.*?\]\1\]/s
  @line_comment ~r/--[^\n]*/
  @error_line ~r/\bat line (\d+)\b/

  @typedoc "Profiles in order of first appearance, fan-out use, and source line count."
  @type outline :: %{profiles: [String.t()], fan_out?: boolean(), lines: pos_integer()}

  @doc "Outlines a workflow script; `nil` when there is no script to outline."
  @spec outline(term()) :: outline() | nil
  def outline(script) when is_binary(script) and script != "" do
    # Comments are blanked rather than removed so match offsets keep the
    # source order of the profiles.
    code = blank(script, @block_comment) |> blank(@line_comment)
    fan_out? = Regex.match?(@parallel, code)
    returned = if fan_out?, do: profiles(@parallel_return, code), else: []

    profiles =
      (profiles(@spawn, code) ++ returned)
      |> Enum.sort_by(fn {offset, _name} -> offset end)
      |> Enum.map(fn {_offset, name} -> name end)
      |> Enum.uniq()

    %{
      profiles: profiles,
      fan_out?: fan_out?,
      lines: script |> String.trim_trailing("\n") |> String.split("\n") |> length()
    }
  end

  def outline(_script), do: nil

  @doc """
  A one-line summary such as `scout → worker · fan-out`.

  At most `max_profiles` names are listed; the rest are counted. Returns `""`
  when the outline names no profile and does not fan out.
  """
  @spec summary(outline() | nil, pos_integer()) :: String.t()
  def summary(outline, max_profiles \\ 4)

  def summary(nil, _max_profiles), do: ""

  def summary(%{profiles: profiles, fan_out?: fan_out?}, max_profiles) do
    {shown, hidden} = Enum.split(profiles, max_profiles)

    chain =
      case {shown, hidden} do
        {[], _} -> []
        {shown, []} -> [Enum.join(shown, " → ")]
        {shown, hidden} -> [Enum.join(shown, " → ") <> " +#{length(hidden)} more"]
      end

    Enum.join(chain ++ if(fan_out?, do: ["fan-out"], else: []), " · ")
  end

  @doc "The script line a workflow error names (`... at line N ...`), if any."
  @spec error_line(term()) :: pos_integer() | nil
  def error_line(message) when is_binary(message) do
    case Regex.run(@error_line, message) do
      [_, line] -> String.to_integer(line)
      _ -> nil
    end
  end

  def error_line(_message), do: nil

  defp profiles(pattern, code) do
    pattern
    |> Regex.scan(code, return: :index)
    |> Enum.map(fn [_match, _quote, {offset, length}] ->
      {offset, binary_part(code, offset, length)}
    end)
  end

  defp blank(text, pattern) do
    Regex.replace(pattern, text, fn match -> String.replace(match, ~r/[^\n]/u, " ") end)
  end
end
