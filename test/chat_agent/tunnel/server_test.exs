defmodule ChatAgent.Tunnel.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Health
  alias ChatAgent.CommanderMock
  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Server
  alias ChatAgent.Tunnel.Status
  alias ChatAgent.TunnelProviderMock

  # Every failure path here logs on purpose, so the suite would otherwise read
  # as though something went wrong. A failing test still prints what it logged.
  @moduletag :capture_log

  @os_pid 4242
  @url "https://a1b2c3.ngrok-free.app"

  # The state machine does its work from its own process, so the mocks have to
  # answer calls made from there.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Registration goes through a mocked channel: what is under test here is
    # when the machine registers, not how a service is talked to.
    channels = Application.get_env(:chat_agent, Channel)
    Application.put_env(:chat_agent, Channel, adapters: [mock: ChatAgent.ChannelMock])
    on_exit(fn -> Application.put_env(:chat_agent, Channel, channels) end)

    stub(TunnelProviderMock, :name, fn -> "test_provider" end)
    stub(TunnelProviderMock, :authenticate, fn -> :ok end)
    stub(TunnelProviderMock, :command, fn port -> "test_agent http #{port}" end)
    stub(TunnelProviderMock, :parse, &parse/1)
    stub(CommanderMock, :stop, fn _os_pid -> :ok end)
    stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:error, :not_supported} end)

    Tunnel.subscribe()
    on_exit(&Tunnel.unsubscribe/0)

    :ok
  end

  describe "opening a tunnel" do
    test "authenticates, runs the agent, and registers every channel's webhook" do
      test_process = self()

      expect(CommanderMock, :run_link, fn command, options ->
        send(test_process, {:run_link, command, options})
        start_agent()
      end)

      expect(TunnelProviderMock, :authenticate, fn ->
        send(test_process, :authenticate)
        :ok
      end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn url, _options ->
        send(test_process, {:register_webhook, url})
        {:ok, :registered}
      end)

      server = start_server()

      assert_receive :authenticate
      assert_receive {:run_link, "test_agent http 4000", options}
      # The agent's output is the only thing that reports the URL, so both
      # streams have to come back to this process.
      assert :stdout in options
      assert :stderr in options

      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, url_line(@url))

      assert_receive {:register_webhook, "#{@url}/mock/webhook?token=test_mock_webhook_token"}
      assert_receive {:tunnel, %Status{state: :connected, url: @url}}

      assert {:ok, @url} = Server.url(server)

      assert %Status{state: :connected, webhooks: %{mock: {:ok, :registered}}} =
               Server.status(server)
    end

    test "waits for a whole line before reading it, since output arrives in chunks" do
      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:ok, :registered} end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, ~s({"lvl":"info","msg":"starting web service"}\n))

      {head, tail} = String.split_at(url_line(@url), 30)

      agent_says(server, head)
      refute_receive {:tunnel, %Status{state: :connected}}, 50

      agent_says(server, tail <> "\n")
      assert_receive {:tunnel, %Status{state: :connected, url: @url}}
    end

    test "reads a line the agent reports a failure on, and keeps it in the status" do
      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:ok, :registered} end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, ~s({"lvl":"eror","err":"session limit reached"}\n))
      assert %Status{error: "session limit reached"} = Server.status(server)

      # The agent is left to exit on its own rather than being torn down here,
      # and an error line does not swallow what follows it in the same chunk.
      agent_says(server, ~s({"lvl":"eror","err":"retrying"}\n) <> url_line(@url))

      assert_receive {:tunnel, %Status{state: :connected, url: @url}}
    end
  end

  describe "recovering" do
    test "retries authentication after it fails" do
      test_process = self()

      expect(TunnelProviderMock, :authenticate, fn -> {:error, :no_authtoken} end)

      expect(TunnelProviderMock, :authenticate, fn ->
        send(test_process, :authenticated)
        :ok
      end)

      expect(CommanderMock, :run_link, fn _command, _options ->
        send(test_process, :run_link)
        start_agent()
      end)

      start_server()

      assert_receive :authenticated
      assert_receive :run_link
    end

    test "starts the whole cycle again when the agent exits" do
      test_process = self()

      expect(CommanderMock, :run_link, 2, fn _command, _options ->
        send(test_process, :run_link)
        start_agent()
      end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:ok, :registered} end)

      server = start_server()

      assert_receive :run_link
      agent_says(server, url_line(@url))
      assert_receive {:tunnel, %Status{state: :connected}}

      kill_agent(server)

      assert_receive {:tunnel, %Status{state: :authenticating, url: nil}}
      assert_receive :run_link
      # The URL is gone with the agent that held it.
      assert {:error, :not_connected} = Server.url(server)
    end

    test "replaces an agent that never reports a URL" do
      test_process = self()

      expect(CommanderMock, :run_link, 2, fn _command, _options ->
        send(test_process, :run_link)
        start_agent()
      end)

      expect(CommanderMock, :stop, fn os_pid ->
        send(test_process, {:stopped, os_pid})
        :ok
      end)

      start_server(connect_timeout: 50)

      assert_receive :run_link
      assert_receive {:stopped, @os_pid}
      assert_receive :run_link
    end
  end

  describe "registering webhooks" do
    test "tries again when a channel could not be told" do
      test_process = self()

      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:error, :timeout} end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options ->
        send(test_process, :registered)
        {:ok, :registered}
      end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, url_line(@url))

      assert_receive :registered
      assert_receive {:tunnel, %Status{state: :connected}}
    end

    test "asks a channel that cannot register only once" do
      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, 1, fn _url, _options ->
        {:error, :not_supported}
      end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, url_line(@url))

      assert_receive {:tunnel, %Status{state: :connected}}
      assert %Status{webhooks: %{mock: {:error, :not_supported}}} = Server.status(server)
    end

    test "registers again when the agent reports a different URL" do
      test_process = self()

      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, 2, fn url, _options ->
        send(test_process, {:register_webhook, url})
        {:ok, :registered}
      end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      agent_says(server, url_line(@url))
      assert_receive {:register_webhook, _url}
      assert_receive {:tunnel, %Status{state: :connected, url: @url}}

      # The agent repeats itself on a reconnect. The same URL is the one it
      # already has, so nobody is told about it again.
      agent_says(server, url_line(@url))
      refute_receive {:register_webhook, _url}, 50

      agent_says(server, url_line("https://d4e5f6.ngrok-free.app"))

      assert_receive {:register_webhook,
                      "https://d4e5f6.ngrok-free.app/mock/webhook?token=test_mock_webhook_token"}

      assert_receive {:tunnel, %Status{state: :connected, url: "https://d4e5f6.ngrok-free.app"}}
    end
  end

  describe "configuration" do
    test "forwards to the port the endpoint actually bound" do
      test_process = self()

      # `port: 0` asks the operating system for a port, so the configuration
      # cannot answer this one: only the running listener can.
      endpoint = Application.get_env(:chat_agent, ChatAgentWeb.Endpoint)
      on_exit(fn -> restart_endpoint(endpoint) end)

      restart_endpoint(Keyword.merge(endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 0]))

      {:ok, {_ip, bound_port}} = ChatAgentWeb.Endpoint.server_info(:http)
      assert bound_port != 0

      expect(CommanderMock, :run_link, fn command, _options ->
        send(test_process, {:run_link, command})
        start_agent()
      end)

      start_server(port: nil)

      expected = "test_agent http #{bound_port}"
      assert_receive {:run_link, ^expected}
    end

    test "falls back to the endpoint's configured port when nothing is listening" do
      test_process = self()

      endpoint = Application.get_env(:chat_agent, ChatAgentWeb.Endpoint)
      on_exit(fn -> Application.put_env(:chat_agent, ChatAgentWeb.Endpoint, endpoint) end)

      Application.put_env(
        :chat_agent,
        ChatAgentWeb.Endpoint,
        Keyword.put(endpoint, :http, port: 4321)
      )

      expect(CommanderMock, :run_link, fn command, _options ->
        send(test_process, {:run_link, command})
        start_agent()
      end)

      start_server(port: nil)

      assert_receive {:run_link, "test_agent http 4321"}
    end

    test "reports an agent that could not be started, and tries again" do
      test_process = self()

      expect(CommanderMock, :run_link, fn _command, _options -> {:error, [:enoent]} end)

      expect(CommanderMock, :run_link, fn _command, _options ->
        send(test_process, :run_link)
        start_agent()
      end)

      log =
        capture_log(fn ->
          start_server()
          assert_receive :run_link
        end)

      assert log =~ "tunnel_agent_start_failed"
    end

    test "ignores a message that is neither its agent's output nor its exit" do
      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      server = start_server()
      assert_receive {:tunnel, %Status{state: :connecting}}

      send(server, {:stdout, 9999, "output from an agent this server replaced"})
      send(server, {:EXIT, self(), :normal})

      assert %Status{state: :connecting} = Server.status(server)
    end

    test "logs every state it moves through, and the URL it opened" do
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:ok, :registered} end)

      log =
        capture_log(fn ->
          server = start_server()
          assert_receive {:tunnel, %Status{state: :connecting}}

          agent_says(server, ~s({"lvl":"info","msg":"starting web service"}\n))
          agent_says(server, url_line(@url))
          assert_receive {:tunnel, %Status{state: :connected}}
        end)

      assert log =~ "tunnel_state_changed"
      # Starting up is not a retry of anything, so it has no previous state.
      assert log =~ "from: :none"
      assert log =~ "to: :authenticating"
      assert log =~ "to: :connecting"
      assert log =~ "to: :registering"
      assert log =~ "to: :connected"
      assert log =~ "tunnel_agent_started"
      assert log =~ "tunnel_webhook_registered"
      # Every other line the agent writes, for when the agent is the problem.
      assert log =~ "tunnel_agent_output"
      assert log =~ @url
    end
  end

  describe "status/1" do
    test "reports a server that is not running, rather than raising" do
      assert %Status{state: :down} = Server.status(:no_such_tunnel)
    end
  end

  describe "renew/1" do
    test "stops the agent and opens another tunnel, which is another URL" do
      test_process = self()

      expect(CommanderMock, :run_link, 2, fn _command, _options -> start_agent() end)

      expect(CommanderMock, :stop, fn os_pid ->
        send(test_process, {:stopped, os_pid})
        :ok
      end)

      expect(ChatAgent.ChannelMock, :register_webhook, 2, fn url, _options ->
        send(test_process, {:register_webhook, url})
        {:ok, :registered}
      end)

      server = start_server()
      agent_says(server, url_line(@url))
      assert_receive {:tunnel, %Status{state: :connected, url: @url}}
      assert_receive {:register_webhook, _url}

      assert :ok = Server.renew(server)

      # The agent it had is stopped, and the URL it had goes with it: what the
      # service handed out is gone before another is asked for.
      assert_receive {:stopped, @os_pid}
      assert_receive {:tunnel, %Status{state: :authenticating, url: nil}}

      renewed = "https://d4e5f6.ngrok-free.app"
      webhook = "#{renewed}/mock/webhook?token=test_mock_webhook_token"
      agent_says(server, url_line(renewed))

      assert_receive {:register_webhook, ^webhook}
      assert_receive {:tunnel, %Status{state: :connected, url: ^renewed}}
    end

    test "runs the next attempt straight away, rather than after the backoff" do
      # A tunnel that has been failing has a backoff built up. Somebody asking
      # for a new URL is not that retry, and should not wait through it.
      expect(TunnelProviderMock, :authenticate, fn -> {:error, :no_credentials} end)

      server = start_server(max_backoff: 30_000)

      assert_receive {:tunnel, %Status{state: :authenticating, error: nil}}
      # The next attempt of its own is now seconds away.
      assert_receive {:tunnel, %Status{state: :authenticating, error: :no_credentials}}

      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)
      stub(TunnelProviderMock, :authenticate, fn -> :ok end)

      assert :ok = Server.renew(server)

      # Without the reset this waits out a backoff measured in seconds.
      assert_receive {:tunnel, %Status{state: :authenticating, error: nil}}, 500
      assert_receive {:tunnel, %Status{state: :connecting}}, 500
    end

    test "is answerable before there is an agent to stop" do
      expect(TunnelProviderMock, :authenticate, fn -> {:error, :no_credentials} end)
      stub(CommanderMock, :stop, fn _os_pid -> flunk("stopped an agent that never ran") end)

      server = start_server(max_backoff: 30_000)

      assert_receive {:tunnel, %Status{state: :authenticating, error: :no_credentials}}

      stub(TunnelProviderMock, :authenticate, fn -> :ok end)
      expect(CommanderMock, :run_link, fn _command, _options -> start_agent() end)

      assert :ok = Server.renew(server)

      assert_receive {:tunnel, %Status{state: :connecting}}, 500
    end

    test "reports a server that is not running, rather than raising" do
      assert {:error, :down} = Server.renew(:no_such_tunnel)
    end
  end

  describe "delivery health" do
    test "asks every channel how delivery is going, and carries the answer" do
      server = connected_server()

      expect(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, delivering()} end)

      assert_receive {:tunnel, %Status{state: :connected, health: health}}, 500
      assert %{mock: {:ok, %Health{state: :ok, pending: 0}}} = health
      # Still connected: this is a report, not a transition.
      assert %Status{state: :connected} = Server.status(server)
    end

    test "tells a service that is not delivering where to call, again" do
      test_process = self()

      connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, failing()} end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn url, options ->
        send(test_process, {:registered_again, url, options})
        {:ok, :registered}
      end)

      # The registration already points here, which is exactly why it has to be
      # written rather than read: only the write makes the service look the
      # address up again.
      assert_receive {:registered_again, "#{@url}/mock/webhook?token=test_mock_webhook_token",
                      force: true},
                     500
    end

    test "gives up the URL itself once telling the service again has not helped" do
      test_process = self()

      server = connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, failing()} end)
      stub(CommanderMock, :stop, fn os_pid -> send(test_process, {:stopped, os_pid}) && :ok end)

      # Two forced registrations, and then the URL is the only thing left to
      # suspect.
      assert_receive {:stopped, @os_pid}, 1_000
      assert_receive {:tunnel, %Status{state: :authenticating, url: nil}}, 1_000

      assert %Status{url: nil} = Server.status(server)
    end

    test "logs what each check found, where a log is being read" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          connected_server()

          stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, delivering()} end)

          assert_receive {:tunnel, %Status{health: %{mock: {:ok, _health}}}}, 500
        end)

      assert log =~ "channel_delivery_checked"
      assert log =~ "state: :ok"
    end

    test "stops saying delivery is failing once it is not" do
      server = connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, failing()} end)

      # All the way down the ladder, to the state that reports and waits.
      assert_receive {:tunnel, %Status{state: :connecting}}, 1_000
      agent_says(server, url_line(@url))
      assert_receive {:tunnel, %Status{error: :delivery_failing}}, 1_000

      # Whatever was in the way has been moved, somewhere this app cannot see.
      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, delivering()} end)

      assert_receive {:tunnel, %Status{error: nil, health: %{mock: {:ok, %Health{state: :ok}}}}},
                     1_000
    end

    test "stops repairing, and says why, once a new URL did not help either" do
      test_process = self()

      server = connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, failing()} end)
      stub(CommanderMock, :stop, fn os_pid -> send(test_process, {:stopped, os_pid}) && :ok end)

      # Through the ladder: told again, told again, given another URL, and told
      # again on that one too.
      assert_receive {:tunnel, %Status{state: :connecting}}, 1_000
      agent_says(server, url_line(@url))

      assert_receive {:tunnel, %Status{error: :delivery_failing}}, 1_000

      # The checks carry on, so a failure that ends elsewhere is still noticed,
      # but nothing more is thrown away over it: no further agent is stopped,
      # which is what renewing one would start with.
      flush()
      refute_receive {:stopped, _os_pid}, 200
    end

    test "does not repair on a check that could not be made" do
      connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn -> {:error, :timeout} end)

      stub(ChatAgent.ChannelMock, :register_webhook, fn _url, _options ->
        flunk("re-registered because a service could not be reached to be asked")
      end)

      assert_receive {:tunnel, %Status{health: %{mock: {:error, :timeout}}}}, 500

      flush()
      refute_receive {:tunnel, %Status{state: :registering}}, 200
    end

    test "treats a service that points somewhere else as one that cannot deliver" do
      test_process = self()

      connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn ->
        {:ok,
         %Health{
           delivering()
           | url:
               "https://somebody-elses-tunnel.example.com/mock/webhook?token=test_mock_webhook_token"
         }}
      end)

      expect(ChatAgent.ChannelMock, :register_webhook, fn url, options ->
        send(test_process, {:registered_again, url, options})
        {:ok, :registered}
      end)

      assert_receive {:registered_again, "#{@url}/mock/webhook?token=test_mock_webhook_token",
                      force: true},
                     500
    end

    test "asks a channel that cannot answer only once" do
      test_process = self()

      connected_server()

      stub(ChatAgent.ChannelMock, :webhook_health, fn ->
        send(test_process, :asked)
        {:error, :not_supported}
      end)

      assert_receive :asked, 500
      # Several intervals later, and it has not been asked again: retrying
      # cannot change that answer.
      refute_receive :asked, 200
    end
  end

  describe "check_health/1" do
    test "asks now, rather than at the next interval" do
      test_process = self()

      # Long enough that nothing here could be the interval coming round.
      connected_server(health_interval: 60_000)

      stub(ChatAgent.ChannelMock, :webhook_health, fn ->
        send(test_process, :asked)
        {:ok, delivering()}
      end)

      refute_receive :asked, 100

      assert :ok = Server.check_health()

      assert_receive :asked, 500
      assert_receive {:tunnel, %Status{health: %{mock: {:ok, %Health{state: :ok}}}}}, 500
    end

    test "reports a tunnel with no URL open, which has nothing to check yet" do
      expect(TunnelProviderMock, :authenticate, fn -> {:error, :no_credentials} end)

      server = start_server(max_backoff: 30_000)

      assert_receive {:tunnel, %Status{state: :authenticating, error: :no_credentials}}

      assert {:error, :not_connected} = Server.check_health(server)
    end

    test "reports a server that is not running, rather than raising" do
      assert {:error, :down} = Server.check_health(:no_such_tunnel)
    end
  end

  ### ==========================================================================
  ### Helpers
  ### ==========================================================================

  # A tunnel that has reached `:connected`, which is the only state that has
  # delivery to answer for.
  defp connected_server(options \\ []) do
    stub(CommanderMock, :run_link, fn _command, _options -> start_agent() end)
    stub(ChatAgent.ChannelMock, :register_webhook, fn _url, _options -> {:ok, :registered} end)

    server = start_server(Keyword.put_new(options, :health_interval, 30))

    assert_receive {:tunnel, %Status{state: :connecting}}
    agent_says(server, url_line(@url))
    assert_receive {:tunnel, %Status{state: :connected}}

    server
  end

  defp delivering do
    %Health{
      state: :ok,
      url: "#{@url}/mock/webhook?token=test_mock_webhook_token",
      pending: 0,
      checked_at: DateTime.utc_now()
    }
  end

  defp failing do
    %Health{
      delivering()
      | state: :failing,
        pending: 3,
        last_error: "Connection timed out",
        last_error_at: DateTime.utc_now()
    }
  end

  defp start_server(options \\ []) do
    options =
      Keyword.merge(
        [provider: TunnelProviderMock, port: 4000, connect_timeout: 500, max_backoff: 10],
        options
      )

    start_supervised!({Server, options})
  end

  # Stands in for erlexec: the process it returns is linked to the caller, which
  # is the state machine, exactly as `:exec.run_link/2` leaves it.
  defp start_agent do
    pid = spawn_link(fn -> Process.sleep(:infinity) end)

    {:ok, pid, @os_pid}
  end

  defp agent_says(server, output), do: send(server, {:stdout, @os_pid, output})

  # What a state machine did on the way here is already in the mailbox, and a
  # `refute_receive` about what it does next would find it there.
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp kill_agent(server) do
    %{exec_pid: pid} = :sys.get_state(server) |> elem(1)

    Process.exit(pid, :kill)
  end

  defp restart_endpoint(config) do
    Application.put_env(:chat_agent, ChatAgentWeb.Endpoint, config)

    :ok = Supervisor.terminate_child(ChatAgent.Supervisor, ChatAgentWeb.Endpoint)
    {:ok, _pid} = Supervisor.restart_child(ChatAgent.Supervisor, ChatAgentWeb.Endpoint)

    :ok
  end

  defp url_line(url), do: ~s({"lvl":"info","msg":"started tunnel","url":"#{url}"}\n)

  defp parse(line) do
    case Jason.decode(line) do
      {:ok, %{"msg" => "started tunnel", "url" => url}} -> {:ok, url}
      {:ok, %{"lvl" => "eror", "err" => error}} -> {:error, error}
      _other -> :ignore
    end
  end
end
