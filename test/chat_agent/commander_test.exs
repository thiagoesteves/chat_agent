defmodule ChatAgent.CommanderTest do
  use ExUnit.Case, async: false

  import Mox

  alias ChatAgent.Commander
  alias ChatAgent.CommanderMock

  setup :verify_on_exit!

  describe "the configured adapter" do
    test "runs a linked command through it" do
      expect(CommanderMock, :run_link, fn command, options ->
        assert command == "ngrok http 4000"
        assert options == [:stdout]
        {:ok, self(), 4242}
      end)

      assert {:ok, _pid, 4242} = Commander.run_link("ngrok http 4000", [:stdout])
    end

    test "runs a command through it" do
      expect(CommanderMock, :run, fn command, options ->
        assert command == "ngrok config check"
        assert options == [:sync]
        {:ok, []}
      end)

      assert {:ok, []} = Commander.run("ngrok config check", [:sync])
    end

    test "stops a process through it" do
      expect(CommanderMock, :stop, fn 4242 -> :ok end)

      assert :ok = Commander.stop(4242)
    end

    test "sends to a process through it" do
      expect(CommanderMock, :send, fn 4242, "quit\n" -> :ok end)

      assert :ok = Commander.send(4242, "quit\n")
    end

    test "reports the operating system through it" do
      expect(CommanderMock, :os_type, fn -> {:unix, :darwin} end)

      assert {:unix, :darwin} = Commander.os_type()
    end
  end
end
