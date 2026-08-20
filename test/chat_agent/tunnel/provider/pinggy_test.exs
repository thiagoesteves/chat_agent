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

      assert Pinggy.command(4000) == "ssh -p 443 -R0:localhost:4000 free.pinggy.io"
    end

    test "uses the configured SSH endpoint and passes extra arguments before it" do
      configure(
        executable: "/usr/bin/ssh",
        ssh_port: 22,
        host: "example.pinggy.io",
        extra_args: ["-v"]
      )

      assert Pinggy.command(3000) ==
               "/usr/bin/ssh -p 22 -R0:localhost:3000 -v example.pinggy.io"
    end
  end

  describe "parse/1" do
    test "reads the HTTPS URL from Pinggy output" do
      line = "https://uljtt-30-47-152-61.run.pinggy-free.link"

      assert {:ok, ^line} = Pinggy.parse(line)
    end

    test "prefers the HTTPS URL when output includes both URLs" do
      line = "http://example.run.pinggy-free.link https://secure.run.pinggy-free.link"

      assert {:ok, "https://secure.run.pinggy-free.link"} = Pinggy.parse(line)
    end

    test "ignores output without an HTTPS URL" do
      assert :ignore = Pinggy.parse("Warning: Permanently added host to known hosts")
      assert :ignore = Pinggy.parse("http://example.run.pinggy-free.link")
    end
  end
end
