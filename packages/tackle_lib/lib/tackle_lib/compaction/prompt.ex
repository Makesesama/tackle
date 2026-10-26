defmodule Tackle.Lib.Compaction.Prompt do
  @moduledoc """
  Deterministic instructions for the default LLM summarizer.

  The directive is appended as the final user message of the summarization
  request, after the existing system prompt, tool definitions, and shadowed
  messages. Keeping the prefix byte-identical to the live request lets the
  provider reuse its warm prompt cache. An earlier checkpoint is the first
  shadowed message, so the directive only asks to merge it and never repeats
  it.

  The fixed sections maximise recall first: exact files, commands, decisions,
  errors, and pending work survive compaction. Optional caller instructions may
  add focus but never remove these invariants.
  """

  @sections """
  Produce a single checkpoint summary that lets another agent continue this work
  without the original messages. Obey these rules:

    * Preserve the user's corrections and failed attempts; they prevent repeats.
    * Record exact file paths, symbols, commands, and short code snippets.
    * Keep critical ids, values, and references needed to resume.
    * Remove stale or superseded facts.
    * If the conversation begins with an earlier checkpoint summary, merge its
      still-valid facts and drop what the newer messages supersede.
    * Do not call tools. Do not narrate or mention the compaction itself.
  Write terse Markdown with exactly these sections:

  ## Goal
  ## Constraints and preferences
  ## Completed work
  ## In progress and blocked
  ## Decisions and rationale
  ## Files, commands, and symbols
  ## Errors and failed approaches
  ## Pending jobs
  ## Next step
  ## Critical references
  """

  @doc """
  Builds the compaction directive as the final user message content.

  `:instructions` adds the operator's focus after the fixed rules.
  """
  @spec directive(keyword()) :: String.t()
  def directive(opts \\ []) do
    [@sections, instructions_block(Keyword.get(opts, :instructions))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp instructions_block(nil), do: nil
  defp instructions_block(""), do: nil

  defp instructions_block(instructions) when is_binary(instructions) do
    """
    Additional focus requested by the operator (it may add emphasis but must not
    remove any rule above):

    #{instructions}
    """
  end
end
