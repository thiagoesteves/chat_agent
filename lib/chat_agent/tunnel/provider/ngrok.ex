defmodule ChatAgent.Tunnel.Provider.Ngrok do
  @moduledoc """
  Tunnel provider backed by the ngrok agent.

  Runs `ngrok http <port>` and reads the URL back out of the agent's own log:
  with `--log=stdout --log-format=json` the agent writes one JSON object per
  line instead of painting a terminal UI, and the line announcing the tunnel
  carries the URL it was assigned.

  ## Requirements

  The `ngrok` executable must be on the PATH, and the agent must hold an
  authtoken. `authenticate/0` writes the configured token when there is one,
  and otherwise checks the agent's stored configuration, which is what a
  previous `ngrok config add-authtoken` leaves behind.

  ## Configuration

      config :chat_agent, ChatAgent.Tunnel.Provider.Ngrok,
        # Path to the agent, when it is not simply on the PATH.
        executable: "ngrok",
        # Set from NGROK_AUTHTOKEN. Without it the agent's own stored token is
        # used, so a machine that has run `ngrok config add-authtoken` needs
        # nothing here.
        authtoken: nil,
        # A reserved domain, so the public URL survives a restart. Without one
        # the agent is assigned a new URL on every run, and every channel is
        # told about it again.
        domain: nil,
        log_level: "info",
        # Anything else to pass to `ngrok http`, one argument per element.
        extra_args: []
  """

  @behaviour ChatAgent.Tunnel.Provider.Adapter

  alias ChatAgent.Commander

  require Logger

  # The token ends up inside a shell command, so it is checked against what an
  # authtoken can contain rather than escaped. A token that fails this is a
  # mistyped configuration value, not a token.
  @authtoken_format ~r/^[A-Za-z0-9_\-]+$/

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def name, do: "ngrok"

  @impl true
  def authenticate do
    # Looked for before anything is run, so an agent that is not installed is
    # reported as exactly that. Left to the run, it arrives as an exit status
    # wrapping a sentence from a shell, which reads like ngrok refused rather
    # than like ngrok is absent.
    case System.find_executable(executable()) do
      nil ->
        {:error, {:executable_not_found, executable()}}

      _path ->
        case config()[:authtoken] do
          # No token given, so the agent's stored one has to do. `config check`
          # is what reports whether it has any.
          nil -> run("#{executable()} config check")
          token -> authenticate(token)
        end
    end
  end

  @impl true
  def command(port) do
    Enum.join(
      [
        executable(),
        "http",
        to_string(port),
        # Without these the agent paints a terminal UI and reports nothing that
        # can be read back.
        "--log=stdout",
        "--log-format=json",
        "--log-level=#{config()[:log_level] || "info"}"
      ] ++ domain_args() ++ extra_args(),
      " "
    )
  end

  @impl true
  def parse(line) do
    case Jason.decode(line) do
      {:ok, %{"msg" => "started tunnel", "url" => url}} ->
        {:ok, url}

      {:ok, %{"lvl" => level} = entry} when level in ["eror", "error", "crit"] ->
        {:error, entry["err"] || entry["msg"]}

      # Anything else the agent logs, and anything that is not one of its log
      # lines at all, such as a message the shell itself wrote.
      _other ->
        :ignore
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp authenticate(token) do
    if Regex.match?(@authtoken_format, token) do
      run("#{executable()} config add-authtoken #{token}")
    else
      {:error, :invalid_authtoken}
    end
  end

  # The token is in the command, so a failure is reported by what it was doing
  # rather than by echoing the command back.
  defp run(command) do
    case Commander.run(command, [:sync, :stdout, :stderr]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp domain_args do
    case config()[:domain] do
      nil -> []
      domain -> ["--domain=#{domain}"]
    end
  end

  defp extra_args, do: config()[:extra_args] || []

  defp executable, do: config()[:executable] || "ngrok"

  defp config, do: Application.get_env(:chat_agent, __MODULE__, [])
end
