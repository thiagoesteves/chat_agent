defmodule ChatAgent.Tunnel.Provider.Adapter do
  @moduledoc """
  Behaviour every tunnel agent must implement.

  A provider owns one tunnelling service: how it proves its credentials, the
  command that opens a tunnel, and how to read that command's output. It owns
  nothing about when any of that happens, which is `ChatAgent.Tunnel.Server`'s
  job.

  The commands are run through `ChatAgent.Commander`, so the provider never
  touches the operating system directly and a test can watch what it asked for.

  ## Implementing a new provider

  1. Create a module under `ChatAgent.Tunnel.Provider` that declares
     `@behaviour ChatAgent.Tunnel.Provider.Adapter`.
  2. Implement the four callbacks. `c:command/1` must return a command that
     stays in the foreground and writes its progress to stdout, since that
     output is the only thing that reports the URL.
  3. Point `config :chat_agent, ChatAgent.Tunnel, provider: MyProvider` at it.

  ### Example skeleton

      defmodule ChatAgent.Tunnel.Provider.MyAgent do
        @behaviour ChatAgent.Tunnel.Provider.Adapter

        @impl true
        def name, do: "my_agent"

        @impl true
        def authenticate, do: :ok

        @impl true
        def command(port), do: "my_agent --port \#{port} --log stdout"

        @impl true
        def parse("url=" <> url), do: {:ok, String.trim(url)}
        def parse(_line), do: :ignore
      end
  """

  @doc """
  The agent's name, for logs and for anything showing which tunnel is in use.
  """
  @callback name() :: String.t()

  @doc """
  Prove the agent's credentials before a tunnel is opened.

  Runs before every connection attempt, so it must be cheap and repeatable.
  An agent that stores its credentials on disk should verify them here rather
  than write them again.
  """
  @callback authenticate() :: :ok | {:error, term()}

  @doc """
  The command that opens a tunnel to `port` on this machine.

  It is run with `ChatAgent.Commander.run_link/2` and must stay in the
  foreground: the server treats the command exiting as the tunnel going down.
  """
  @callback command(port :: :inet.port_number()) :: String.t()

  @doc """
  Read one line of the command's output.

  Returns `{:ok, url}` for the line announcing the public URL, `{:error,
  reason}` for a line reporting a failure, and `:ignore` for everything else.
  """
  @callback parse(line :: String.t()) :: {:ok, String.t()} | {:error, term()} | :ignore
end
