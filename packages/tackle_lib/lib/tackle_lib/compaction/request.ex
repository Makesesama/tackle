defmodule Tackle.Lib.Compaction.Request do
  @moduledoc """
  Provider-neutral input to one summarization call.

  The request mirrors the live provider prefix so a summarizer can reuse the
  provider's prompt cache: `:system` is the unchanged system prompt, `:tools`
  are the same tool definitions in the same order, `:messages` are the shadowed
  model messages in their original serialization, and `:instructions` become a
  final user message with the compaction directive.

  A summarizer only produces text plus bounded metadata and usage. It never
  selects the cut, commits durable state, or replaces the model surface.
  """

  alias Tackle.Lib.Compaction.Prompt
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.ModelInfo

  @type t :: %__MODULE__{
          messages: [Message.t()],
          system: String.t() | nil,
          tools: [map()],
          selection: Selection.t() | nil,
          model: String.t() | nil,
          model_info: ModelInfo.t() | nil,
          session_id: String.t() | nil,
          prior_summary: String.t() | nil,
          instructions: String.t() | nil,
          trigger: atom() | nil,
          summary_max_tokens: pos_integer() | nil
        }

  @enforce_keys [:messages]
  defstruct messages: [],
            system: nil,
            tools: [],
            selection: nil,
            model: nil,
            model_info: nil,
            session_id: nil,
            prior_summary: nil,
            instructions: nil,
            trigger: nil,
            summary_max_tokens: nil

  @doc """
  Builds the provider-neutral summarization message array.

  The shadowed messages keep their original role tagging and tool linkage, and
  the compaction directive is appended as one final user message.
  """
  @spec to_provider_messages(t()) :: [map()]
  def to_provider_messages(%__MODULE__{} = request) do
    directive =
      Prompt.directive(prior_summary: request.prior_summary, instructions: request.instructions)

    provider_messages(request.messages) ++ [%{role: :user, content: directive}]
  end

  defp provider_messages(messages), do: Messages.to_provider(messages)
end
