defmodule Tackle.Runtime.Package do
  @moduledoc """
  Reusable OTP orchestration for `Tackle.Lib` agents.

  See `Tackle.Runtime` for the public scope, delegation, workflow, and
  cancellation API. Hosts provide a `Tackle.Runtime.AgentBackend` which owns
  the concrete per-agent process and host lifecycle policy.
  """
end
