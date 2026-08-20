defmodule ChatAgent.Tunnel.Provider.PinggyTest do
  use ExUnit.Case, async: false

  alias ChatAgent.Tunnel.Provider.Pinggy

  setup do
    configured = Application.get_env(:chat_agent, Pinggy)
    on_exit(fn -> Application.put_env(:chat_agent, Pinggy, configured) end)

    :ok
  end

  defp configure(options), do: Application.put_env(:chat_agent, Pinggy, options)

  describe "name/0" do
    test "names the agent it runs" do
      assert Pinggy.name() == "pinggy"
    end
  end

  describe "authenticate/0" do
    test "accepts an installed SSH client" do
      configure(executable: "sh")

      assert :ok = Pinggy.authenticate()
    end

    test "says the agent is missing" do
      configure(executable: "definitely-not-ssh")

      assert {:error, {:executable_not_found, "definitely-not-ssh"}} = Pinggy.authenticate()
    end
  end

  describe "command/1" do
    test "forwards to the given port through Pinggy's SSH endpoint" do
      configure([])

      # Nobody is at the keyboard: a host it has never seen would otherwise
      # stop to ask about the key, and a session that dies quietly would leave
      # ssh running with the tunnel still reported as up.
      assert Pinggy.command(4000) ==
               "ssh -p 443 -R0:localhost:4000 -o StrictHostKeyChecking=no " <>
                 "-o ServerAliveInterval=30 free.pinggy.io"
    end

    test "signs in with the access token, which Pinggy takes as the user" do
      configure(access_token: "tok_123")

      assert Pinggy.command(4000) =~ "tok_123@free.pinggy.io"
    end

    test "stays anonymous when the token is empty rather than absent" do
      configure(access_token: "")

      assert String.ends_with?(Pinggy.command(4000), " free.pinggy.io")
    end

    test "uses the configured SSH endpoint and passes extra arguments before it" do
      configure(
        executable: "/usr/bin/ssh",
        ssh_port: 22,
        host: "example.pinggy.io",
        ssh_options: [],
        extra_args: ["-v"]
      )

      assert Pinggy.command(3000) ==
               "/usr/bin/ssh -p 22 -R0:localhost:3000 -v example.pinggy.io"
    end

    test "passes each configured ssh option as its own -o" do
      configure(ssh_options: ["ExitOnForwardFailure=yes", "ServerAliveCountMax=3"])

      assert Pinggy.command(4000) =~
               "-o ExitOnForwardFailure=yes -o ServerAliveCountMax=3"
    end
  end

  describe "parse/1" do
    test "reads a URL announced on a line of its own" do
      line = "https://uljtt-30-47-152-61.run.pinggy-free.link"

      assert {:ok, ^line} = Pinggy.parse(line)
      assert {:ok, ^line} = Pinggy.parse("  #{line}  ")
    end

    test "takes no URL that something else is talking about" do
      # Every line here is real output from a Pinggy session. Taking the first
      # URL on any line takes the openssh.com warning first, and the state
      # machine then registers somebody else's domain as this app's webhook.
      assert :ignore =
               Pinggy.parse(
                 "** The server may need to be upgraded. See https://openssh.com/pq.html"
               )

      assert :ignore =
               Pinggy.parse(
                 "Your tunnel will expire in 60 minutes. Upgrade to Pinggy Pro to get " <>
                   "unrestricted tunnels. https://dashboard.pinggy.io"
               )
    end

    test "ignores everything else a session prints" do
      assert :ignore =
               Pinggy.parse(
                 "Pseudo-terminal will not be allocated because stdin is not a terminal."
               )

      assert :ignore = Pinggy.parse("Allocated port 3 for remote forward to localhost:4000")
      assert :ignore = Pinggy.parse("You are not authenticated.")
      assert :ignore = Pinggy.parse("Warning: Permanently added host to known hosts")
      assert :ignore = Pinggy.parse("http://example.run.pinggy-free.link")
      assert :ignore = Pinggy.parse("")
    end

    test "reads one URL out of a whole session, and only the tunnel's" do
      taken =
        [
          "Pseudo-terminal will not be allocated because stdin is not a terminal.",
          "** WARNING: connection is not using a post-quantum key exchange algorithm.",
          "** The server may need to be upgraded. See https://openssh.com/pq.html",
          "Allocated port 3 for remote forward to localhost:4000",
          "You are not authenticated.",
          "Your tunnel will expire in 60 minutes. Upgrade to Pinggy Pro to get " <>
            "unrestricted tunnels. https://dashboard.pinggy.io",
          "https://kaxku-179-125-135-54.run.pinggy-free.link",
          "https://xxcyo-179-125-135-54.free.pinggy.net"
        ]
        |> Enum.flat_map(fn line ->
          case Pinggy.parse(line) do
            {:ok, url} -> [url]
            :ignore -> []
          end
        end)

      # Both belong to the same tunnel and either one works; nothing else does.
      assert taken == [
               "https://kaxku-179-125-135-54.run.pinggy-free.link",
               "https://xxcyo-179-125-135-54.free.pinggy.net"
             ]
    end
  end
end
