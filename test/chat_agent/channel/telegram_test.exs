defmodule ChatAgent.Channel.TelegramTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias ChatAgent.Channel.Message
  alias ChatAgent.Channel.Telegram

  describe "handle_message/1" do
    test "processes a text message" do
      update = %{
        "update_id" => 1,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "text" => "Hello"
        }
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.id == "1"
      assert parsed.sender == "123456"
      assert parsed.conversation == "123456"
      assert parsed.identifiers == [{"chat.id", "123456"}, {"from.id", "123456"}]
      assert parsed.text == "Hello"
      assert %DateTime{} = parsed.received_at
    end

    test "separates the person from the conversation in a group" do
      update = %{
        "update_id" => 2,
        "message" => %{
          "chat" => %{"id" => -1_001_234_567_890},
          "from" => %{"id" => 42},
          "text" => "Hello"
        }
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.sender == "42"
      assert parsed.conversation == "-1001234567890"
      assert parsed.identifiers == [{"chat.id", "-1001234567890"}, {"from.id", "42"}]
    end

    test "falls back to the chat when the payload names no sender" do
      update = %{
        "update_id" => 3,
        "message" => %{"chat" => %{"id" => 99}, "text" => "Hello"}
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.sender == "99"
      assert parsed.conversation == "99"
    end

    test "processes an unknown update" do
      assert :ok = Telegram.handle_message(%{"update_id" => 1})
    end
  end

  describe "send_message/2" do
    test "posts a text message to the Bot API" do
      Req.Test.stub(Telegram, fn conn ->
        assert conn.method == "POST"
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      assert :ok = Telegram.send_message(123_456, "Hello")
    end

    test "reports a failure the Bot API answers 200 with" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "chat not found"})
      end)

      assert {:error, {:telegram_error, "chat not found"}} = Telegram.send_message(0, "Hello")
    end

    test "reports an unexpected status" do
      Req.Test.stub(Telegram, fn conn ->
        Plug.Conn.send_resp(conn, 502, "Bad Gateway")
      end)

      assert {:error, {:http_error, 502}} = Telegram.send_message(123_456, "Hello")
    end

    test "reports a transport error" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Telegram.send_message(123_456, "Hello")
    end
  end

  describe "authenticate/1" do
    test "accepts a request carrying the configured secret" do
      request = conn(:post, "/telegram/webhook", "")

      request =
        Plug.Conn.put_req_header(
          request,
          "x-telegram-bot-api-secret-token",
          "test_telegram_webhook_secret"
        )

      assert :ok = Telegram.authenticate(request)
    end

    test "rejects a request with the wrong secret" do
      request = conn(:post, "/telegram/webhook", "")
      request = Plug.Conn.put_req_header(request, "x-telegram-bot-api-secret-token", "wrong")

      assert {:error, :forbidden} = Telegram.authenticate(request)
    end

    test "rejects a request with no secret header at all" do
      assert {:error, :forbidden} = Telegram.authenticate(conn(:post, "/telegram/webhook", ""))
    end

    test "accepts any request when no secret is configured" do
      configured = Application.get_env(:chat_agent, :telegram_webhook_secret)
      on_exit(fn -> Application.put_env(:chat_agent, :telegram_webhook_secret, configured) end)
      Application.put_env(:chat_agent, :telegram_webhook_secret, nil)

      assert :ok = Telegram.authenticate(conn(:post, "/telegram/webhook", ""))
    end
  end

  describe "reference/0" do
    test "names the identifiers and where they are documented" do
      reference = Telegram.reference()

      assert reference.url =~ "core.telegram.org"
      assert {"chat.id", _} = Enum.find(reference.fields, &match?({"chat.id", _}, &1))
      assert {"from.id", _} = Enum.find(reference.fields, &match?({"from.id", _}, &1))
    end
  end

  describe "verify_subscription/1" do
    test "reports that the Bot API performs no handshake" do
      assert {:error, :not_found} = Telegram.verify_subscription(%{})
    end
  end

  describe "inbound_messages/1" do
    test "returns the update as the only payload" do
      update = %{"update_id" => 1, "message" => %{"text" => "Hello"}}

      assert {:ok, [^update]} = Telegram.inbound_messages(update)
    end

    test "rejects a body that is not an update" do
      assert {:error, :bad_request} = Telegram.inbound_messages(%{})
    end
  end
end
