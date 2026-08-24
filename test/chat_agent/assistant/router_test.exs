defmodule ChatAgent.Assistant.RouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ChatAgent.Assistant
  alias ChatAgent.Assistant.Router
  alias ChatAgent.Assistant.Session
  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message

  # Every failure path here logs on purpose, so the suite would otherwise read
  # as though something went wrong. A failing test still prints what it logged.
  @moduletag :capture_log

  @password "test_assistant_password"

  # The router works from its own process, and its sessions from theirs again,
  # so the mocks have to serve calls from anywhere.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    configured = Application.get_env(:chat_agent, Assistant)

    Application.put_env(
      :chat_agent,
      Assistant,
      Keyword.put(configured, :salted_password, Pbkdf2.hash_pwd_salt(@password))
    )

    on_exit(fn -> Application.put_env(:chat_agent, Assistant, configured) end)

    channels = Application.get_env(:chat_agent, Channel)
    Application.put_env(:chat_agent, Channel, adapters: [mock: ChatAgent.ChannelMock])
    on_exit(fn -> Application.put_env(:chat_agent, Channel, channels) end)

    :ok
  end

  # Its own name and its own session supervisor, so a test never shares either
  # with another test or with the application.
  defp start_router(options \\ []) do
    unique = System.unique_integer([:positive])
    supervisor = :"assistant_sessions_#{unique}"

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: supervisor, strategy: :one_for_one},
        id: unique
      )
    )

    start_supervised!(
      {Router,
       Keyword.merge(
         [name: :"assistant_router_#{unique}", session_supervisor: supervisor],
         options
       )}
    )
  end

  # What a channel delivers, as the facade broadcasts it.
  defp say(text, conversation \\ "123456") do
    Phoenix.PubSub.broadcast(
      ChatAgent.PubSub,
      Channel.topic(:mock),
      {:message,
       %Message{
         channel: :mock,
         conversation: conversation,
         sender: conversation,
         text: text,
         direction: :inbound,
         received_at: DateTime.utc_now()
       }}
    )
  end

  # Ends the open session and waits for the router to have noticed, rather than
  # for the reply that comes first: the session answers the person, then stops,
  # and only then does the router hear about it.
  defp stop_session(router) do
    %{{:mock, "123456"} => %{pid: pid}} = Router.sessions(router)
    reference = Process.monitor(pid)

    expect_reply("Session closed")
    say("/stop")

    assert_receive {:replied, _body}
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}

    _ = :sys.get_state(router)

    :ok
  end

  defp expect_reply(matching) do
    test_process = self()

    expect(ChatAgent.ChannelMock, :send_message, fn _recipient, body ->
      assert body =~ matching
      send(test_process, {:replied, body})
      :ok
    end)
  end

  describe "authenticating" do
    test "opens a session on the default assistant" do
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth #{@password}")

      assert_receive {:replied, _body}
      assert %{{:mock, "123456"} => session} = Router.sessions(router)
      assert %{assistant: :claude, id: id, pid: pid} = session
      # The identifier is short enough to read out in a chat.
      assert String.length(id) == 6
      assert %{assistant: :claude, id: ^id} = Session.state(pid)
    end

    test "opens a session on an assistant named in the attempt" do
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth-claude #{@password}")

      assert_receive {:replied, _body}
      assert map_size(Router.sessions(router)) == 1
    end

    test "checks the password against a hash, not against a password" do
      # Nothing in the configuration is what somebody types, so reading it,
      # the logs, or a crash dump gives no way in.
      configured = Application.get_env(:chat_agent, Assistant)[:salted_password]

      refute configured == @password
      assert String.starts_with?(configured, "$pbkdf2")
      assert Pbkdf2.verify_pass(@password, configured)
    end

    test "answers a wrong password with nothing at all" do
      router = start_router()

      say("/auth not-the-password")

      # With `verify_on_exit!` and no expectation, any reply fails this test.
      # Saying "wrong password" would confirm to whoever is guessing that a
      # password is what opens this.
      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}
    end

    test "ignores a message that is not an attempt" do
      router = start_router()

      say("hello?")

      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}
    end

    test "says so when the attempt names an assistant that is not configured" do
      expect_reply("No assistant called gpt here")
      router = start_router()

      say("/auth-gpt #{@password}")

      assert_receive {:replied, _body}
      assert Router.sessions(router) == %{}
    end

    test "lets nobody in when no password is configured" do
      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.delete(Application.get_env(:chat_agent, Assistant), :salted_password)
      )

      router = start_router()

      say("/auth anything")
      say(~s(/auth ""))

      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}
    end

    test "opens the session in a working directory the conversation named" do
      root = Path.join(System.tmp_dir!(), "router_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "my-app-folder"))
      on_exit(fn -> File.rm_rf!(root) end)

      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.put(Application.get_env(:chat_agent, Assistant), :working_dir_root, root)
      )

      expect_reply("in my-app-folder")
      router = start_router()

      say("/auth #{@password} --work-dir my-app-folder")

      assert_receive {:replied, body}
      # Named in the greeting, so the conversation knows where it is working.
      assert body =~ "Talking to claude in my-app-folder"

      assert %{{:mock, "123456"} => %{working_dir: working_dir}} = Router.sessions(router)
      assert working_dir == Path.join(root, "my-app-folder")
    end

    test "opens in the configured default when the conversation names nothing" do
      root = Path.join(System.tmp_dir!(), "router_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "chat_agent"))
      on_exit(fn -> File.rm_rf!(root) end)

      Application.put_env(
        :chat_agent,
        Assistant,
        Application.get_env(:chat_agent, Assistant)
        |> Keyword.put(:working_dir_root, root)
        |> Keyword.put(:working_dir, "chat_agent")
      )

      expect_reply("in chat_agent")
      router = start_router()

      say("/auth #{@password}")

      assert_receive {:replied, _body}
      assert %{{:mock, "123456"} => %{working_dir: working_dir}} = Router.sessions(router)
      assert working_dir == Path.join(root, "chat_agent")
    end

    test "refuses a working directory that is not on offer" do
      root = Path.join(System.tmp_dir!(), "router_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.put(Application.get_env(:chat_agent, Assistant), :working_dir_root, root)
      )

      expect_reply("No working directory called ../.. here")
      router = start_router()

      say("/auth #{@password} --work-dir ../..")

      assert_receive {:replied, _body}
      # No session at all: it asked for somewhere it may not go.
      assert Router.sessions(router) == %{}
    end

    test "says so when no working directory is on offer at all" do
      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.delete(Application.get_env(:chat_agent, Assistant), :working_dir_root)
      )

      expect_reply("No working directories are offered here")
      router = start_router()

      log =
        capture_log(fn ->
          say("/auth #{@password} --work-dir my-app-folder")
          assert_receive {:replied, _body}
        end)

      # Plain for whoever asked, and named for whoever configured it: the usual
      # reason is a root set somewhere nothing reads.
      assert log =~ "no :working_dir_root configured under ChatAgent.Assistant"
      assert Router.sessions(router) == %{}
    end

    test "holds one session per conversation" do
      expect(ChatAgent.ChannelMock, :send_message, 2, fn _recipient, _body -> :ok end)
      router = start_router()

      say("/auth #{@password}", "111")
      say("/auth #{@password}", "222")

      _ = :sys.get_state(router)
      sessions = Router.sessions(router)

      assert map_size(sessions) == 2
      assert sessions[{:mock, "111"}].pid != sessions[{:mock, "222"}].pid
      assert sessions[{:mock, "111"}].id != sessions[{:mock, "222"}].id
    end
  end

  describe "routing" do
    setup do
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth #{@password}")
      assert_receive {:replied, _body}

      %{router: router}
    end

    test "hands what is said to the session holding that conversation" do
      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, prompt, _options ->
        send(test_process, {:asked, prompt})
        {:ok, "an answer"}
      end)

      expect_reply("an answer")

      say("What is OTP?")

      assert_receive {:asked, "User: What is OTP?"}
      assert_receive {:replied, _body}
    end

    test "stays answerable while a session waits on a slow assistant", %{router: router} do
      test_process = self()

      stub(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        send(test_process, :thinking)
        Process.sleep(300)
        {:ok, "eventually"}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      say("a slow question")
      assert_receive :thinking

      {elapsed, _state} = :timer.tc(fn -> :sys.get_state(router) end)

      # The router answered for itself while a session was waiting. Asked in
      # the router's own process, it would have been 300ms behind.
      assert elapsed < 100_000
    end

    test "forgets a conversation whose session was closed", %{router: router} do
      stop_session(router)

      assert Router.sessions(router) == %{}
    end

    test "starts over after a session ends", %{router: router} do
      stop_session(router)

      # Nothing is answered until it authenticates again.
      say("are you there?")
      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}

      expect_reply("Talking to claude")
      say("/auth #{@password}")
      assert_receive {:replied, _body}
      assert map_size(Router.sessions(router)) == 1
    end
  end

  describe "replies it could not deliver" do
    test "says so, rather than leaving a message missing everywhere" do
      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, _body ->
        {:error, {:telegram_error, "chat not found"}}
      end)

      router = start_router()

      log =
        capture_log(fn ->
          say("/auth #{@password}")
          _ = :sys.get_state(router)
        end)

      assert log =~ "assistant_reply_not_sent"
      # The session still opened: what failed was telling the person so.
      assert map_size(Router.sessions(router)) == 1
    end
  end

  describe "the public URL" do
    setup do
      configured = Application.get_env(:chat_agent, ChatAgent.Tunnel)

      on_exit(fn -> Application.put_env(:chat_agent, ChatAgent.Tunnel, configured) end)

      :ok
    end

    defp tunnel(config), do: Application.put_env(:chat_agent, ChatAgent.Tunnel, config)

    test "answers a conversation that knows the password, without opening a session" do
      # Whoever is setting a webhook up needs the URL before there is a session
      # to ask from, and the password is what says they may have it.
      tunnel(url: "https://example.test")
      expect_reply("https://example.test")
      router = start_router()

      say("/auth #{@password} --url")

      assert_receive {:replied, "https://example.test"}
      assert Router.sessions(router) == %{}
    end

    test "answers a conversation with a session open, without asking the assistant" do
      # No expectation on the assistant: Mox raises if it is asked anyway.
      tunnel(url: "https://example.test/")
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth #{@password}")
      assert_receive {:replied, _body}

      expect_reply("https://example.test")
      say("/auth #{@password} --url")

      assert_receive {:replied, "https://example.test"}
      # The session it was said in is untouched.
      assert map_size(Router.sessions(router)) == 1
    end

    test "answers a wrong password with nothing at all" do
      # The same silence a wrong password gets anywhere else: saying "wrong
      # password" is what confirms to whoever is guessing that one opens this.
      tunnel(url: "https://example.test")
      router = start_router()

      say("/auth not-the-password --url")

      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}
    end

    test "says so while a tunnel has not connected yet" do
      tunnel(provider: ChatAgent.Tunnel.Provider.Ngrok)
      expect_reply("still connecting")
      start_router()

      say("/auth #{@password} --url")

      assert_receive {:replied, _body}
    end

    test "says so when there is no public URL at all" do
      tunnel([])
      expect_reply("No public URL is configured")
      start_router()

      say("/auth #{@password} --url")

      assert_receive {:replied, _body}
    end

    test "is not the word on its own, which a session hears as anything else" do
      tunnel(url: "https://example.test")
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth #{@password}")
      assert_receive {:replied, _body}

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, prompt, _options ->
        assert prompt == "User: /url please"
        {:ok, "an answer"}
      end)

      expect_reply("an answer")
      say("/url please")

      assert_receive {:replied, _body}
      assert map_size(Router.sessions(router)) == 1
    end
  end

  describe "renewing the public URL" do
    setup do
      configured = Application.get_env(:chat_agent, ChatAgent.Tunnel)

      on_exit(fn -> Application.put_env(:chat_agent, ChatAgent.Tunnel, configured) end)

      :ok
    end

    # Standing in for the state machine under the name it registers, since what
    # is under test here is what the router asks for and what it says about the
    # answer, not what opening a tunnel does. `ChatAgent.Tunnel.Server` has its
    # own test for that.
    defp tunnel_server(answer) do
      test_process = self()

      pid =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, :renew} ->
              send(test_process, :renew_asked)
              :gen.reply(from, answer)
          end
        end)

      Process.register(pid, ChatAgent.Tunnel.Server)

      pid
    end

    test "runs the tunnel again, and opens no session doing it" do
      tunnel(provider: ChatAgent.Tunnel.Provider.Ngrok)
      tunnel_server(:ok)
      expect_reply("Renewing the public URL")
      router = start_router()

      say("/auth #{@password} --renew")

      assert_receive :renew_asked
      assert_receive {:replied, _body}
      assert Router.sessions(router) == %{}
    end

    test "says so when a tunnel is configured but is not running" do
      tunnel(provider: ChatAgent.Tunnel.Provider.Ngrok)
      expect_reply("No tunnel is running here")
      start_router()

      say("/auth #{@password} --renew")

      assert_receive {:replied, _body}
    end

    test "says so when the URL is a static one, which no agent opened" do
      tunnel(url: "https://example.test")
      expect_reply("nothing to renew")
      start_router()

      say("/auth #{@password} --renew")

      assert_receive {:replied, _body}
    end

    test "answers a wrong password with nothing at all, and renews nothing" do
      tunnel(provider: ChatAgent.Tunnel.Provider.Ngrok)
      tunnel_server(:ok)
      router = start_router()

      say("/auth not-the-password --renew")

      _ = :sys.get_state(router)
      refute_received :renew_asked
      assert Router.sessions(router) == %{}
    end

    test "leaves a session that asked for it exactly as it was" do
      tunnel(url: "https://example.test")
      expect_reply("Talking to claude")
      router = start_router()

      say("/auth #{@password}")
      assert_receive {:replied, _body}

      sessions = Router.sessions(router)

      expect_reply("nothing to renew")
      say("/auth #{@password} --renew")

      assert_receive {:replied, _body}
      assert Router.sessions(router) == sessions
    end
  end

  describe "messages it did not ask for" do
    test "ignores anything else sent to it" do
      router = start_router()

      send(router, :something_it_does_not_know)
      send(router, {:message, :not_a_message_struct})
      send(router, {:DOWN, make_ref(), :process, self(), :normal})

      _ = :sys.get_state(router)
      assert Router.sessions(router) == %{}
    end

    test "says so when a session cannot be started" do
      # A supervisor already at its limit, which is what refusing to start a
      # session looks like from here.
      full = :"assistant_sessions_full_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {DynamicSupervisor, name: full, strategy: :one_for_one, max_children: 0},
          id: full
        )
      )

      expect_reply("could not start a session")
      router = start_router(session_supervisor: full)

      say("/auth #{@password}")

      assert_receive {:replied, _body}
      assert Router.sessions(router) == %{}
    end
  end
end
