defmodule ChatAgent.Tunnel.Provider.Pinggy do
  @moduledoc """
  Tunnel provider backed by Pinggy's SSH tunnel service.

  Runs the system `ssh` client with remote port forwarding and reads the HTTPS
  URL that Pinggy prints on stdout after the tunnel is connected.

  ## Requirements

  The `ssh` executable must be on the PATH. Pinggy's free service does not
  require an account or token; when SSH asks for a password, leave it blank.

  ## Configuration

      config :chat_agent, ChatAgent.Tunnel.Provider.Pinggy,
        executable: "ssh",
        host: "free.pinggy.io",
        ssh_port: 443,
        # Additional arguments passed to `ssh`, one argument per element.
        extra_args: []
  """

  @behaviour ChatAgent.Tunnel.Provider.Adapter

  @impl true
  def name, do: "pinggy"

  @impl true
  def authenticate do
    case System.find_executable(executable()) do
      nil -> {:error, {:executable_not_found, executable()}}
      _path -> :ok
    end
  end

  @impl true
  def command(port) do
    Enum.join(
      [
        executable(),
        "-p",
        to_string(config()[:ssh_port] || 443),
        "-R0:localhost:#{port}"
      ] ++ extra_args() ++ [host()],
      " "
    )
  end

  @impl true
  def parse(line) do
    case Regex.run(~r{https://[^\s]+}, String.trim(line)) do
      [url] -> {:ok, String.trim_trailing(url, ".")}
      _none -> :ignore
    end
  end

  defp extra_args, do: config()[:extra_args] || []

  defp executable, do: config()[:executable] || "ssh"

  defp host, do: config()[:host] || "free.pinggy.io"

  defp config, do: Application.get_env(:chat_agent, __MODULE__, [])
end
