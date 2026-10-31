defmodule Tackle.Hub.AgentConfig do
  @moduledoc """
  Configuration of ephemeral review agents, which run on
  `Tackle.Runtime.LoopAgent` without the local harness.

  Every configuration carries one owner's stable database credential-store
  handle (`Tackle.Hub.CredentialStore.handle/1`), which `LoopAgent` puts into
  every model call's adapter options and which reconfiguration cannot
  replace. The host supplies tools and executor context; agents neither choose
  an executor nor persist conversations.
  """

  alias Tackle.Hub.CredentialStore
  alias Tackle.Runtime.LoopAgent

  @doc """
  Builds a `Tackle.Runtime.LoopAgent.Config` from `:providers` (from
  `Tackle.Hub.Models.enabled_providers/1` of one owner), `:owner_id` (the
  user the providers belong to), `:model`, and the other options of
  `Tackle.Runtime.LoopAgent.Config.new/1`. The model must resolve against the
  supplied providers; there is no implicit model.
  """
  @spec new(keyword()) :: {:ok, LoopAgent.Config.t()} | {:error, term()}
  def new(opts) do
    {owner_id, opts} = Keyword.pop!(opts, :owner_id)
    LoopAgent.Config.new(Keyword.put(opts, :credential_store, CredentialStore.handle(owner_id)))
  end
end
