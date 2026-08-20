defmodule ChatAgent.Tunnel.Provider.Pinggy do
  @moduledoc """
  Tunnel provider backed by Pinggy's SSH tunnel service.

  Runs the system `ssh` client with remote port forwarding and reads the HTTPS
  URL that Pinggy prints on stdout after the tunnel is connected.

  ## Requirements

  The `ssh` executable must be on the PATH. The free service needs no account,
  and a token is what buys a tunnel that lasts and a name that stays: Pinggy
  takes it as the SSH user, so `token@free.pinggy.io`.

  A free tunnel expires after an hour. The agent exits when it does, which the
  state machine treats as any other exit: it opens another one and tells every
  channel where its webhook moved to. Expect an hourly re-registration, and a
  gap between the old tunnel closing and the new one being registered.

  ## Configuration

      config :chat_agent, ChatAgent.Tunnel.Provider.Pinggy,
        executable: "ssh",
        host: "free.pinggy.io",
        ssh_port: 443,
        # Set from PINGGY_ACCESS_TOKEN. Without one the tunnel is anonymous,
        # which is the free service.
        access_token: nil,
        # Passed as `-o`, one per element. The defaults are what makes ssh
        # usable with nobody at the keyboard: a host it has never seen would
        # otherwise stop to ask about the key, and a session that dies quietly
        # would otherwise leave ssh running and the tunnel reported as up.
        ssh_options: ["StrictHostKeyChecking=no", "ServerAliveInterval=30"],
        # Additional arguments passed to `ssh`, one argument per element.
        extra_args: []
  """

  @behaviour ChatAgent.Tunnel.Provider.Adapter

  # Nobody is at the keyboard to accept a host key, and nothing else notices a
  # session that stops carrying traffic without closing.
  @default_ssh_options ["StrictHostKeyChecking=no", "ServerAliveInterval=30"]

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
      ] ++ ssh_options() ++ extra_args() ++ [endpoint()],
      " "
    )
  end

  # Pinggy announces a tunnel by printing its URL on a line of its own. Every
  # other URL that crosses this output belongs to something else: ssh warns
  # about post-quantum key exchange with a link to openssh.com, and Pinggy
  # advertises its dashboard in the line about the tunnel expiring. Taking the
  # first URL on any line takes those, and the state machine then registers
  # somebody else's domain as this app's webhook.
  @impl true
  def parse(line) do
    case String.trim(line) do
      "https://" <> _rest = url -> if url?(url), do: {:ok, url}, else: :ignore
      _other -> :ignore
    end
  end

  # A URL and nothing else: one token, no spaces, and nothing after it.
  defp url?(url), do: not String.contains?(url, " ")

  # The token is the SSH user, which is how Pinggy tells a paid tunnel from an
  # anonymous one.
  defp endpoint do
    case config()[:access_token] do
      nil -> host()
      "" -> host()
      token -> "#{token}@#{host()}"
    end
  end

  defp ssh_options do
    (config()[:ssh_options] || @default_ssh_options)
    |> Enum.flat_map(&["-o", &1])
  end

  defp extra_args, do: config()[:extra_args] || []

  defp executable, do: config()[:executable] || "ssh"

  defp host, do: config()[:host] || "free.pinggy.io"

  defp config, do: Application.get_env(:chat_agent, __MODULE__, [])
end
