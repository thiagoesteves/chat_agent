defmodule ChatAgent.Assistant.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  require Logger

  alias ChatAgent.Assistant
  alias ChatAgent.Assistant.Session
  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message

  # Every failure path here logs on purpose, so the suite would otherwise read
  # as though something went wrong. A failing test still prints what it logged.
  @moduletag :capture_log

  @key {:mock, "123456"}

  # A session answers from its own process, so the mocks serve any process.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    channels = Application.get_env(:chat_agent, Channel)
    Application.put_env(:chat_agent, Channel, adapters: [mock: ChatAgent.ChannelMock])
    on_exit(fn -> Application.put_env(:chat_agent, Channel, channels) end)

    configured = Application.get_env(:chat_agent, Assistant)
    on_exit(fn -> Application.put_env(:chat_agent, Assistant, configured) end)

    :ok
  end

  defp start_session(assistant \\ :claude) do
    start_supervised!({Session, key: @key, assistant: assistant, id: "abc123"})
  end

  defp said(text) do
    Message.new(
      channel: :mock,
      conversation: "123456",
      sender: "123456",
      text: text,
      direction: :inbound
    )
  end

  defp expect_reply(matching) do
    test_process = self()

    expect(ChatAgent.ChannelMock, :send_message, fn recipient, body ->
      assert recipient == "123456"
      assert body =~ matching
      send(test_process, {:replied, body})
      :ok
    end)
  end

  describe "answering" do
    test "asks the assistant and sends the answer back" do
      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn conversation, prompt, _options ->
        assert conversation == "123456"
        assert prompt == "User: What is OTP?"
        send(test_process, :asked)
        {:ok, "A runtime for building distributed systems."}
      end)

      expect_reply("A runtime for building distributed systems.")

      session = start_session()
      Session.say(session, said("What is OTP?"))

      assert_receive :asked
      assert_receive {:replied, _body}
    end

    test "asks the assistant to work where the session was opened" do
      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, options ->
        send(test_process, {:options, options})
        {:ok, "done"}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      session =
        start_supervised!(
          {Session,
           key: @key,
           assistant: :claude,
           id: "abc123",
           working_dir: "/srv/checkouts/my-app-folder"}
        )

      Session.say(session, said("what changed?"))

      assert_receive {:options, options}
      assert options[:working_dir] == "/srv/checkouts/my-app-folder"
    end

    test "carries the conversation so far into the next prompt" do
      stub(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:ok, "Yes."}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      session = start_session()
      Session.say(session, said("first"))
      _ = Session.state(session)

      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, prompt, _options ->
        send(test_process, {:prompt, prompt})
        {:ok, "Yes."}
      end)

      Session.say(session, said("second"))

      assert_receive {:prompt, prompt}
      assert prompt == "User: first\nAssistant: Yes.\nUser: second"
    end

    test "keeps only the last turns, so a long conversation stays a prompt" do
      stub(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:ok, "ok"}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      session = start_session()

      # history_limit is 4 in the test environment: two turns of two.
      for number <- 1..4 do
        Session.say(session, said("message #{number}"))
        _ = Session.state(session)
      end

      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, prompt, _options ->
        send(test_process, {:prompt, prompt})
        {:ok, "ok"}
      end)

      Session.say(session, said("newest"))

      assert_receive {:prompt, prompt}
      refute prompt =~ "message 1"
      assert prompt =~ "newest"
      assert length(String.split(prompt, "\n")) == 4
    end

    test "never carries a password into a prompt, even said inside a session" do
      test_process = self()

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, prompt, _options ->
        send(test_process, {:prompt, prompt})
        {:ok, "noted"}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      session = start_session()
      Session.say(session, said("/auth hunter2"))

      assert_receive {:prompt, prompt}
      refute prompt =~ "hunter2"
      assert prompt =~ "*****"
    end
  end

  describe "failures" do
    setup do
      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)
      :ok
    end

    test "tells the person when an answer took too long" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, :timeout}
      end)

      expect_reply("took too long")

      session = start_session()
      Session.say(session, said("anything"))

      assert_receive {:replied, _body}
    end

    test "stays vague about a failure that describes this machine" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, {:command_failed, "/opt/somewhere/claude: permission denied"}}
      end)

      test_process = self()

      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, body ->
        # Where the tool lives is nobody else's business.
        refute body =~ "somewhere"
        send(test_process, {:replied, body})
        :ok
      end)

      session = start_session()
      Session.say(session, said("anything"))

      assert_receive {:replied, body}
      assert body =~ "Sorry, I could not answer that"
    end

    test "passes on what the tool said when it is about the service" do
      limit = "You've hit your session limit · resets 2:10pm (America/Sao_Paulo)"

      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, {:command_failed, limit}}
      end)

      expect_reply(limit)

      session = start_session()
      reference = Process.monitor(session)

      Session.say(session, said("anything"))

      # The person waiting is told why, in the tool's own words, rather than
      # left with an apology they can do nothing with. A time zone in it is not
      # a path, so it is not held back.
      assert_receive {:replied, body}
      assert body =~ "claude could not answer"
      # And the session ends, since it cannot answer the next one either.
      assert_receive {:DOWN, ^reference, :process, ^session, :normal}
    end

    test "closes when the tool is not installed, since that will not change" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, {:executable_not_found, "claude"}}
      end)

      expect_reply("claude is not installed here")

      session = start_session()
      reference = Process.monitor(session)

      Session.say(session, said("anything"))

      assert_receive {:replied, _body}
      assert_receive {:DOWN, ^reference, :process, ^session, :normal}
    end

    test "closes on a failure it has no words for" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, :something_nobody_wrote_a_sentence_for}
      end)

      expect_reply("Sorry, I could not answer that")

      session = start_session()
      reference = Process.monitor(session)

      Session.say(session, said("anything"))

      assert_receive {:replied, _body}
      assert_receive {:DOWN, ^reference, :process, ^session, :normal}
    end

    test "reports a reply the channel would not carry" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:ok, "an answer nobody receives"}
      end)

      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, _body ->
        {:error, {:telegram_error, "chat not found"}}
      end)

      # A reply that was not sent is broadcast to nobody either, so without
      # this it would be missing from the dashboard with nothing said anywhere.
      log =
        capture_log(fn ->
          session = start_session()
          Session.say(session, said("anything"))
          _ = Session.state(session)
        end)

      assert log =~ "assistant_reply_not_sent"
      assert log =~ "chat not found"
    end

    test "keeps the session open after a failure, and forgets the failed turn" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, :timeout}
      end)

      expect_reply("took too long")

      session = start_session()
      Session.say(session, said("anything"))
      assert_receive {:replied, _body}

      assert Process.alive?(session)
      # The question is remembered, the answer that never came is not.
      assert %{history: [{:user, "anything"}]} = Session.state(session)
    end
  end

  describe "closing" do
    test "stops when asked, and says so" do
      expect_reply("Session closed")

      session = start_session()
      reference = Process.monitor(session)

      Session.say(session, said("/stop"))

      assert_receive {:replied, _body}
      assert_receive {:DOWN, ^reference, :process, ^session, :normal}
    end

    test "tells the conversation it closed, rather than only the log" do
      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.put(Application.get_env(:chat_agent, Assistant), :session_timeout, 50)
      )

      expect_reply("Session closed after a while with nothing said")

      session = start_session()
      reference = Process.monitor(session)

      # A session that ends in silence is indistinguishable, from the
      # conversation, from an assistant that stopped answering.
      assert_receive {:replied, _body}, 1_000
      assert_receive {:DOWN, ^reference, :process, ^session, :normal}
    end

    test "counts what it waited in the words somebody would use" do
      for {timeout, said} <- [{60_000, "a minute"}, {300_000, "5 minutes"}] do
        Application.put_env(
          :chat_agent,
          Assistant,
          Keyword.put(Application.get_env(:chat_agent, Assistant), :session_timeout, timeout)
        )

        session =
          start_supervised!({Session, key: @key, assistant: :claude, id: "abc123"}, id: timeout)

        # Waiting minutes for this would be minutes of test: what is under test
        # is the wording, not the waiting.
        expect_reply(said)
        send(session, :timeout)

        assert_receive {:replied, _body}
      end
    end

    test "stops when nothing is said for long enough" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.put(Application.get_env(:chat_agent, Assistant), :session_timeout, 50)
      )

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      log =
        capture_log(fn ->
          session = start_session()
          reference = Process.monitor(session)

          assert_receive {:DOWN, ^reference, :process, ^session, :normal}, 1_000
        end)

      assert log =~ "assistant_session_expired"
    end

    test "an answer puts the idle timer back" do
      Application.put_env(
        :chat_agent,
        Assistant,
        Keyword.put(Application.get_env(:chat_agent, Assistant), :session_timeout, 200)
      )

      stub(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:ok, "ok"}
      end)

      stub(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      session = start_session()

      for _ <- 1..3 do
        Process.sleep(80)
        Session.say(session, said("still here"))
        _ = Session.state(session)
      end

      # Well past the timeout in total, but never idle for it.
      assert Process.alive?(session)
    end

    test "ignores anything else sent to it" do
      session = start_session()

      send(session, :something_it_does_not_know)

      assert %{history: []} = Session.state(session)
    end
  end
end
