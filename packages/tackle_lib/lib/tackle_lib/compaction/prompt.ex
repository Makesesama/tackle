defmodule Tackle.Lib.Compaction.Prompt do
  @moduledoc """
  Deterministic instructions for the default LLM summarizer.

  The directive is appended as the final user message of the summarization
  request, after the existing system prompt, tool definitions, and shadowed
  messages. Keeping the prefix byte-identical to the live request lets the
  provider reuse its warm prompt cache.

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
    * Merge still-valid facts from an earlier checkpoint when one is provided.
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

  @doc "Builds the compaction directive as the final user message content."
  @spec directive(keyword()) :: String.t()
  def directive(opts \\ []) do
    prior = Keyword.get(opts, :prior_summary)
    instructions = Keyword.get(opts, :instructions)

    [
      @sections,
      prior_block(prior),
      instructions_block(instructions)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp prior_block(nil), do: nil
  defp prior_block(""), do: nil

  defp prior_block(prior) when is_binary(prior) do
    """
    The text between the markers is the previous checkpoint summary. Merge what
    is still valid and drop what the newer conversation supersedes.

    <<<PREVIOUS CHECKPOINT
    #{prior}
    PREVIOUS CHECKPOINT>>>
    """
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
