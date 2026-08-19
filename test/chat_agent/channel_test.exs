defmodule ChatAgent.ChannelTest do
  use ExUnit.Case, async: false

  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message

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

  describe "register_webhook/2" do
    test "hands the channel its own webhook URL, built from the public one" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :register_webhook, fn url ->
        assert url == "https://a1b2c3.ngrok-free.app/mock/webhook"
        {:ok, :registered}
      end)

      assert {:ok, :registered} =
               Channel.register_webhook(:mock, "https://a1b2c3.ngrok-free.app")
    end

    test "returns the channel result unchanged" do
      stub_channel()

      expect(ChatAgent.ChannelMock, :register_webhook, fn _url -> {:error, :not_supported} end)

      assert {:error, :not_supported} = Channel.register_webhook(:mock, "https://example.com")
    end

    test "reports a channel with no module configured" do
      assert {:error, {:unknown_channel, :carrier_pigeon}} =
               Channel.register_webhook(:carrier_pigeon, "https://example.com")
    end
  end

  describe "webhook_url/2" do
    test "follows the route shape every channel webhook is served on" do
      assert Channel.webhook_url(:telegram, "https://example.com") ==
               "https://example.com/telegram/webhook"
    end

    test "does not double the separator when the base URL ends in one" do
      assert Channel.webhook_url(:whatsapp, "https://example.com/") ==
               "https://example.com/whatsapp/webhook"
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
