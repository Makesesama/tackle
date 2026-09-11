defmodule Tackle.Lib.Interaction do
  @moduledoc """
  Provider-neutral, frontend-supplied interaction handle for adapter flows.

  Tackle.Lib never writes to a terminal or reads user input directly. When an
  adapter needs to show instructions, ask for a secret, confirm a destructive
  action, or display progress while it waits on the provider, it receives this
  handle through the `:interaction` option and calls these functions. The host
  supplies an implementation module and an opaque reference as
  `{module, reference}`, mirroring `Tackle.Lib.CredentialStore`.

  This is what lets a provider adapter own its complete login flow while
  remaining independent of any particular frontend. A CLI can back the handle
  with a terminal library, a test can back it with a scripted process, and a
  headless host can supply an implementation that always declines.

  ## Example

      defmodule MyAdapter do
        @behaviour Tackle.Lib.LLM

        @impl true
        def login(opts) do
          with {:ok, interaction} <- fetch_interaction(opts),
               :ok <- Tackle.Lib.Interaction.info(interaction, "Open the provider portal."),
               {:ok, token} <-
                 Tackle.Lib.Interaction.prompt(interaction,
                   label: "API token",
                   secret: true
                 ) do
            {:ok, %{"token" => token}}
          end
        end

        defp fetch_interaction(opts), do: Keyword.fetch(opts, :interaction)
      end
  """

  @type handle :: {module(), term()}
  @type prompt_result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Displays an informational message to the user.

  The message is iodata so adapters can interleave plain text with
  frontend-provided styled terms without depending on the frontend.
  """
  @callback info(reference :: term(), message :: iodata()) :: :ok

  @doc """
  Requests one line of text.

  Required option `:label` names the requested value. Optional `:secret`
  (`true` when the value must not be echoed), `:default`, and any other
  implementation-specific options may be supplied.
  """
  @callback prompt(reference :: term(), opts :: keyword()) :: prompt_result()

  @doc """
  Asks a yes/no question.

  Implementations must return `false` for anything that is not an explicit
  affirmative answer, so a missing or unreadable terminal never implies
  consent.
  """
  @callback confirm(reference :: term(), message :: iodata()) :: boolean()

  @doc """
  Runs `fun` while displaying progress described by `opts`.

  Adapters use this for provider work that blocks on the user, such as polling
  a device-code flow. `opts` may include `:label`, `:ok`, and `:error`.
  Implementations must return the result of `fun` unchanged.
  """
  @callback progress(reference :: term(), opts :: keyword(), (-> result)) :: result
            when result: var

  @doc "Displays an informational message through the supplied handle."
  @spec info(handle(), iodata()) :: :ok
  def info({module, reference}, message) when is_atom(module) and not is_nil(module) do
    module.info(reference, message)
  end

  @doc "Requests one line of text through the supplied handle."
  @spec prompt(handle(), keyword()) :: prompt_result()
  def prompt({module, reference}, opts)
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    module.prompt(reference, opts)
  end

  @doc "Asks a yes/no question through the supplied handle."
  @spec confirm(handle(), iodata()) :: boolean()
  def confirm({module, reference}, message) when is_atom(module) and not is_nil(module) do
    module.confirm(reference, message)
  end

  @doc "Runs `fun` with progress feedback through the supplied handle."
  @spec progress(handle(), keyword(), (-> result)) :: result when result: var
  def progress({module, reference}, opts, fun)
      when is_atom(module) and not is_nil(module) and is_list(opts) and is_function(fun, 0) do
    module.progress(reference, opts, fun)
  end
end
