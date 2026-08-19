defmodule ChatAgent.Tunnel.Provider.NgrokTest do
  use ExUnit.Case, async: false

  import Mox

  alias ChatAgent.CommanderMock
  alias ChatAgent.Tunnel.Provider.Ngrok

  setup :verify_on_exit!

  setup do
    configured = Application.get_env(:chat_agent, Ngrok)
    on_exit(fn -> Application.put_env(:chat_agent, Ngrok, configured) end)

    :ok
  end

  defp configure(options), do: Application.put_env(:chat_agent, Ngrok, options)

  describe "name/0" do
    test "names the agent it runs" do
      assert Ngrok.name() == "ngrok"
    end
  end

  describe "authenticate/0" do
    test "writes the configured authtoken to the agent" do
      configure(authtoken: "2abcDEF_ghi-jkl")

      expect(CommanderMock, :run, fn command, options ->
        assert command == "ngrok config add-authtoken 2abcDEF_ghi-jkl"
        assert :sync in options
        {:ok, []}
      end)

      assert :ok = Ngrok.authenticate()
    end

    test "checks the agent's stored configuration when no token is given" do
      configure([])

      expect(CommanderMock, :run, fn command, _options ->
        assert command == "ngrok config check"
        {:ok, []}
      end)

      assert :ok = Ngrok.authenticate()
    end

    test "runs the configured executable rather than one found on the PATH" do
      configure(executable: "/opt/homebrew/bin/ngrok")

      expect(CommanderMock, :run, fn command, _options ->
        assert command == "/opt/homebrew/bin/ngrok config check"
        {:ok, []}
      end)

      assert :ok = Ngrok.authenticate()
    end

    test "refuses a token that is not one, rather than passing it to a shell" do
      configure(authtoken: "token; rm -rf /")

      assert {:error, :invalid_authtoken} = Ngrok.authenticate()
    end

    test "reports what the agent failed with" do
      configure([])

      expect(CommanderMock, :run, fn _command, _options ->
        {:error, [exit_status: 256, stderr: ["authentication failed"]]}
      end)

      assert {:error, [exit_status: 256, stderr: ["authentication failed"]]} =
               Ngrok.authenticate()
    end

    test "reports an answer it does not recognise as a failure" do
      configure([])

      expect(CommanderMock, :run, fn _command, _options -> :something_else end)

      assert {:error, :something_else} = Ngrok.authenticate()
    end
  end

  describe "command/1" do
    test "forwards to the given port, logging where it can be read back" do
      configure([])

      assert Ngrok.command(4000) ==
               "ngrok http 4000 --log=stdout --log-format=json --log-level=info"
    end

    test "asks for the reserved domain, so the URL survives a restart" do
      configure(domain: "chat.ngrok.app")

      assert Ngrok.command(4000) =~ "--domain=chat.ngrok.app"
    end

    test "passes on anything else the configuration adds" do
      configure(log_level: "debug", extra_args: ["--region=eu"])

      command = Ngrok.command(4000)

      assert command =~ "--log-level=debug"
      assert command =~ "--region=eu"
    end
  end

  describe "parse/1" do
    test "reads the URL out of the line announcing the tunnel" do
      line =
        ~s({"addr":"http://localhost:4000","lvl":"info","msg":"started tunnel",) <>
          ~s("name":"command_line","obj":"tunnels","url":"https://a1b2c3.ngrok-free.app"})

      assert {:ok, "https://a1b2c3.ngrok-free.app"} = Ngrok.parse(line)
    end

    test "reports a line the agent logged an error on" do
      line = ~s({"err":"authentication failed","lvl":"eror","msg":"failed to auth session"})

      assert {:error, "authentication failed"} = Ngrok.parse(line)
    end

    test "falls back to the message when the error carries no reason" do
      assert {:error, "tunnel session failed"} =
               Ngrok.parse(~s({"lvl":"crit","msg":"tunnel session failed"}))
    end

    test "ignores every other line it logs" do
      assert :ignore = Ngrok.parse(~s({"lvl":"info","msg":"starting web service"}))
    end

    test "ignores output that is not one of its log lines" do
      assert :ignore = Ngrok.parse("ngrok: command not found")
    end
  end
end
