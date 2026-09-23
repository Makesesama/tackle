defmodule Tackle.Runtime.Messaging do
  @moduledoc """
  Scope-local routing of model-facing messages.

  Routes envelopes to the recipient's backend without owning another process
  or imposing a common host mailbox. Backends accept or reject delivery
  synchronously; they own queueing, persistence, and turn wake-up. Ordinary
  agent messages require a live sender; deferred completions may outlive theirs.
  """

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Registry

  @doc "Delivers an envelope to one in-scope agent."
  @spec deliver(AgentRef.t(), Envelope.t()) :: :ok | {:error, term()}
  def deliver(%AgentRef{} = to, %Envelope{} = envelope) do
    with {:ok, envelope} <-
           Envelope.new(envelope.kind, envelope.from, envelope.message, envelope.origin),
         :ok <- same_scope(envelope.from, to),
         :ok <- sender_available(envelope),
         {:ok, recipient} <- Registry.whereis(to),
         {:ok, backend} <- Registry.backend(to) do
      try do
        backend.call(recipient, :deliver, [envelope])
      rescue
        error -> {:error, {:agent_backend_failed, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:agent_unavailable, reason}}
      end
    end
  end

  defp same_scope(%AgentRef{scope_id: scope_id}, %AgentRef{scope_id: scope_id}), do: :ok
  defp same_scope(_from, _to), do: {:error, :scope_mismatch}

  defp sender_available(%Envelope{kind: :message, from: from}) do
    with {:ok, coordinator} <- Registry.coordinator(from),
         {:ok, _sender} <- Coordinator.agent_snapshot(coordinator, from) do
      :ok
    end
  end

  defp sender_available(%Envelope{}), do: :ok
end
