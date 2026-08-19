defmodule ChatAgent.Assistant.Adapter do
  @moduledoc """
  Behaviour that every assistant must implement.

  One module per thing that can answer a person, owning how it is reached and
  what its failures are called. `ChatAgent.Assistant.Claude` runs a command line
  tool; another could call an API instead.

  An implementation should report a missing tool or missing credentials as
  itself, rather than as whatever the failure looked like underneath: the
  router turns the reason into what the person waiting is told.

  ## Implementing one

  1. Create a module under `ChatAgent.Assistant` declaring
     `@behaviour ChatAgent.Assistant.Adapter`.
  2. Implement `c:send_message/3`.
  3. Register it under a key in the `adapters` list of `ChatAgent.Assistant`.

      defmodule ChatAgent.Assistant.MyAssistant do
        @behaviour ChatAgent.Assistant.Adapter

        @impl true
        def send_message(_conversation, prompt, _options) do
          # answer, or say why not
        end
      end
  """

  @doc """
  Answer `prompt`, on behalf of `conversation`.

  `conversation` identifies who is being answered, for an assistant that keeps
  its own state per conversation. One that does not can ignore it: the session
  carries the history and builds the prompt from it.

  `options` carries what the conversation asked for, which today is
  `:working_dir`. An assistant that has nowhere to work ignores it.

  Known reasons the router words for the person waiting:

    * `{:executable_not_found, name}` - the tool is not installed here
    * `:timeout` - the answer took longer than the assistant allows
    * `{:command_failed, message}` - it ran and refused
  """
  @callback send_message(
              conversation :: String.t(),
              prompt :: String.t(),
              options :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}
end
