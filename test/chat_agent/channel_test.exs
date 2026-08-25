defmodule ChatAgent.ChannelTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  require Logger

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message
  alias ChatAgent.Channel.Token

  setup :verify_on_exit!

  describe "handle_message/2" do
    test "dispatches through the configured channels" do
      message = %{"from" => "1234567890", "id" => "msg_123", "text" => %{"body" => "Hello"}}

      assert :ok = Channel.handle_message(:whatsapp, message)
      assert :ok = Channel.handle_message(:telegram, %{"update_id" => 1})
    end

    test "hands the payload to the channel module untouched" do
      stub_channel()
      payload = %{"from" => "1234567890", "text" => %{"body" => "Hello"}}

      expect(ChatAgent.ChannelMock, :handle_message, fn message ->
        assert message == payload
        :ok
      end)

      assert :ok = Channel.handle_message(:mock, payload)
    end

    test "returns the channel result unchanged" do
      stub_channel()
      expect(ChatAgent.ChannelMock, :handle_message, fn _payload -> {:error, :rejected} end)

      assert {:error, :rejected} = Channel.handle_message(:mock, %{"id" => "msg_123"})
    end

    test "reports a channel with no module configured" do
      assert {:error, {:unknown_channel, :carrier_pigeon}} =
               Channel.handle_message(:carrier_pigeon, %{})
    end
  end

  describe "send_message/3" do
    test "hands the recipient and body to the channel module untouched" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :send_message, fn recipient, body ->
        assert recipient == 123_456
        assert body == "Hello"
        :ok
      end)

      assert :ok = Channel.send_message(:mock, 123_456, "Hello")
    end

    test "returns the channel result unchanged" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, _body ->
        {:error, :undeliverable}
      end)

      assert {:error, :undeliverable} = Channel.send_message(:mock, "anyone", "Hello")
    end

    test "reports a channel with no module configured" do
      assert {:error, {:unknown_channel, :carrier_pigeon}} =
               Channel.send_message(:carrier_pigeon, "anyone", "Hello")
    end

    test "tells subscribers about the reply it sent" do
      stub_channel()
      assert :ok = Channel.subscribe(:mock)

      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, _body -> :ok end)

      assert :ok = Channel.send_message(:mock, 123_456, "On it")

      assert_receive {:message, %Message{} = message}
      assert message.direction == :outbound
      assert message.channel == :mock
      assert message.conversation == "123456"
      assert message.text == "On it"
      assert message.identifiers == [{"to", "123456"}]
    end

    test "says nothing to subscribers when the service refused it" do
      stub_channel()
      assert :ok = Channel.subscribe(:mock)

      expect(ChatAgent.ChannelMock, :send_message, fn _recipient, _body ->
        {:error, :undeliverable}
      end)

      assert {:error, :undeliverable} = Channel.send_message(:mock, "anyone", "Hello")

      refute_receive {:message, _message}
    end
  end

  describe "register_webhook/3" do
    test "hands the channel its own webhook URL, built from the public one" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :register_webhook, fn url, _options ->
        assert url ==
                 "https://a1b2c3.ngrok-free.app/mock/webhook?token=test_mock_webhook_token"

        {:ok, :registered}
      end)

      assert {:ok, :registered} =
               Channel.register_webhook(:mock, "https://a1b2c3.ngrok-free.app")
    end

    test "reads the registration back before writing it, unless told not to" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, options ->
        assert options == []
        {:ok, :unchanged}
      end)

      assert {:ok, :unchanged} = Channel.register_webhook(:mock, "https://example.com")

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, options ->
        assert options == [force: true]
        {:ok, :registered}
      end)

      assert {:ok, :registered} =
               Channel.register_webhook(:mock, "https://example.com", force: true)
    end

    test "returns the channel result unchanged" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url, _options ->
        {:error, :not_supported}
      end)

      assert {:error, :not_supported} = Channel.register_webhook(:mock, "https://example.com")
    end

    test "reports a channel with no module configured" do
      assert {:error, {:unknown_channel, :carrier_pigeon}} =
               Channel.register_webhook(:carrier_pigeon, "https://example.com")
    end
  end

  describe "webhook_health/1" do
    test "asks the channel how delivery is going" do
      stub_channel()

      health = %ChatAgent.Channel.Health{state: :ok, pending: 0}

      expect(ChatAgent.ChannelMock, :webhook_health, fn -> {:ok, health} end)

      assert {:ok, ^health} = Channel.webhook_health(:mock)
    end

    test "returns the channel result unchanged" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :webhook_health, fn -> {:error, :not_supported} end)

      assert {:error, :not_supported} = Channel.webhook_health(:mock)
    end

    test "reports a channel with no module configured" do
      assert {:error, {:unknown_channel, :carrier_pigeon}} =
               Channel.webhook_health(:carrier_pigeon)
    end
  end

  describe "webhook_url/2" do
    test "follows the route shape every channel webhook is served on" do
      assert Channel.webhook_url(:telegram, "https://example.com") ==
               "https://example.com/telegram/webhook?token=test_telegram_webhook_token"
    end

    test "does not double the separator when the base URL ends in one" do
      assert Channel.webhook_url(:whatsapp, "https://example.com/") ==
               "https://example.com/whatsapp/webhook?token=test_whatsapp_webhook_token"
    end

    test "carries the token the channel's own webhook is guarded by" do
      for channel <- [:telegram, :whatsapp] do
        %URI{query: query} = URI.parse(Channel.webhook_url(channel, "https://example.com"))

        assert URI.decode_query(query) == %{"token" => Token.for_channel(channel)}
      end
    end

    test "gives each channel a token of its own, so one URL does not open another" do
      refute Token.for_channel(:telegram) == Token.for_channel(:whatsapp)
    end
  end

  describe "allowed_chat_ids" do
    setup do
      configured = Application.get_env(:chat_agent, ChatAgent.ChannelMock)

      on_exit(fn ->
        case configured do
          nil -> Application.delete_env(:chat_agent, ChatAgent.ChannelMock)
          configured -> Application.put_env(:chat_agent, ChatAgent.ChannelMock, configured)
        end
      end)

      stub_channel()

      :ok
    end

    defp allow(chat_ids) do
      Application.put_env(:chat_agent, ChatAgent.ChannelMock, allowed_chat_ids: chat_ids)
    end

    defp inbound(conversation) do
      %{"from" => conversation, "text" => %{"body" => "hello"}}
    end

    test "talks to anyone when nothing is configured" do
      allow([])

      assert Channel.allowed?(:mock, "123456")
    end

    test "talks to a listed conversation and no other" do
      allow(["123456"])

      assert Channel.allowed?(:mock, "123456")
      refute Channel.allowed?(:mock, "999999")
    end

    test "compares what identifies a conversation, not how it was written" do
      allow([123_456])

      # A chat id is a number in Telegram's payloads and a string in a config
      # file, and both mean the same conversation.
      assert Channel.allowed?(:mock, 123_456)
      assert Channel.allowed?(:mock, "123456")
    end

    test "broadcasts a message from a listed conversation" do
      allow(["123456"])
      Channel.subscribe(:mock)

      expect(ChatAgent.ChannelMock, :handle_message, fn _payload ->
        {:ok, Message.new(sender: "123456", conversation: "123456", text: "hello")}
      end)

      assert :ok = Channel.handle_message(:mock, inbound("123456"))

      assert_receive {:message, %Message{conversation: "123456"}}
    end

    test "ignores a message from anyone else, and tells nobody but the log" do
      # The log says which conversation was turned away, which is how it gets
      # added to the list when it should have been on it.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      allow(["123456"])
      Channel.subscribe(:mock)

      expect(ChatAgent.ChannelMock, :handle_message, fn _payload ->
        {:ok, Message.new(sender: "999999", conversation: "999999", text: "let me in")}
      end)

      log =
        capture_log(fn ->
          # Answered as though it had been handled: a stranger learns nothing
          # from the reply the webhook gives.
          assert :ok = Channel.handle_message(:mock, inbound("999999"))
        end)

      # It reaches no dashboard and no assistant.
      refute_receive {:message, _message}
      assert log =~ "channel_message_ignored"
      assert log =~ "999999"
    end

    test "refuses to send to a conversation nobody listed" do
      allow(["123456"])

      # With `verify_on_exit!` and no expectation, reaching the channel module
      # would fail this test: nothing is sent at all.
      assert {:error, {:conversation_not_allowed, "999999"}} =
               Channel.send_message(:mock, "999999", "hello")
    end

    test "sends to a listed conversation" do
      allow(["123456"])

      expect(ChatAgent.ChannelMock, :send_message, fn "123456", "hello" -> :ok end)

      assert :ok = Channel.send_message(:mock, "123456", "hello")
    end
  end

  describe "list/0" do
    test "returns every configured channel and its module" do
      assert Channel.list() == [
               telegram: ChatAgent.Channel.Telegram,
               whatsapp: ChatAgent.Channel.Whatsapp
             ]
    end
  end

  describe "subscribe/1" do
    test "delivers messages received on the channel, stamped with it" do
      assert :ok = Channel.subscribe(:whatsapp)

      assert :ok =
               Channel.handle_message(:whatsapp, %{
                 "from" => "1234567890",
                 "id" => "msg_123",
                 "text" => %{"body" => "Hello"}
               })

      assert_receive {:message, %Message{} = message}
      assert message.channel == :whatsapp
      assert message.sender == "1234567890"
      assert message.text == "Hello"
    end

    test "does not deliver payloads that carry no message" do
      assert :ok = Channel.subscribe(:whatsapp)

      assert :ok = Channel.handle_message(:whatsapp, %{"statuses" => [%{"id" => "msg_123"}]})

      refute_receive {:message, _message}
    end

    test "delivers only the subscribed channel" do
      assert :ok = Channel.subscribe(:whatsapp)

      assert :ok =
               Channel.handle_message(:telegram, %{
                 "update_id" => 1,
                 "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}
               })

      refute_receive {:message, _message}
    end

    test "unsubscribe/1 stops delivery" do
      assert :ok = Channel.subscribe(:whatsapp)
      assert :ok = Channel.unsubscribe(:whatsapp)

      assert :ok =
               Channel.handle_message(:whatsapp, %{
                 "from" => "1234567890",
                 "text" => %{"body" => "Hello"}
               })

      refute_receive {:message, _message}
    end
  end

  describe "topic/1" do
    test "names a topic per channel" do
      assert Channel.topic(:whatsapp) == "channel:whatsapp"
      assert Channel.topic(:telegram) == "channel:telegram"
    end
  end

  defp stub_channel do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel, adapters: [mock: ChatAgent.ChannelMock])
  end
end
