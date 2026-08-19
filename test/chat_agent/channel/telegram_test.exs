defmodule ChatAgent.Channel.TelegramTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias ChatAgent.Channel.Message
  alias ChatAgent.Channel.Telegram

  describe "handle_message/1" do
    test "processes a text message" do
      # A private chat, where Telegram reports the same number for both: the
      # chat id of a one to one conversation is the user's own id.
      update = %{
        "update_id" => 1,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "from" => %{"id" => 123_456},
          "text" => "Hello"
        }
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.id == "1"
      assert parsed.sender == "123456"
      assert parsed.conversation == "123456"

      assert parsed.identifiers == [
               {"chat.id", "123456"},
               {"from.id", "123456"},
               {"update_id", "1"}
             ]

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

      assert parsed.identifiers == [
               {"chat.id", "-1001234567890"},
               {"from.id", "42"},
               {"update_id", "2"}
             ]
    end

    test "falls back to the chat when the payload names no sender" do
      update = %{
        "update_id" => 3,
        "message" => %{"chat" => %{"id" => 99}, "text" => "Hello"}
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.sender == "99"
      assert parsed.conversation == "99"

      # No from.id arrived, so none is reported rather than echoing the chat id
      # back under a name the payload never used.
      assert parsed.identifiers == [{"chat.id", "99"}, {"update_id", "3"}]
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

  describe "register_webhook/1" do
    test "sets the webhook, with the configured secret, when it points elsewhere" do
      test_process = self()

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => "https://old.example.com"}})

          "/bottest_telegram_bot_token/setWebhook" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_process, {:set_webhook, Jason.decode!(body)})
            Req.Test.json(conn, %{"ok" => true, "result" => true})
        end
      end)

      assert {:ok, :registered} =
               Telegram.register_webhook("https://a1b2c3.ngrok-free.app/telegram/webhook")

      assert_receive {:set_webhook, payload}
      assert payload["url"] == "https://a1b2c3.ngrok-free.app/telegram/webhook"
      assert payload["secret_token"] == "test_telegram_webhook_secret"
    end

    test "sets no secret token when none is configured" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :webhook_secret))

      test_process = self()

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{}})

          "/bottest_telegram_bot_token/setWebhook" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_process, {:set_webhook, Jason.decode!(body)})
            Req.Test.json(conn, %{"ok" => true, "result" => true})
        end
      end)

      assert {:ok, :registered} =
               Telegram.register_webhook("https://example.com/telegram/webhook")

      assert_receive {:set_webhook, payload}
      refute Map.has_key?(payload, "secret_token")
    end

    test "leaves a webhook that already points there alone" do
      Req.Test.stub(Telegram, fn conn ->
        assert conn.request_path == "/bottest_telegram_bot_token/getWebhookInfo"

        Req.Test.json(conn, %{
          "ok" => true,
          "result" => %{"url" => "https://a1b2c3.ngrok-free.app/telegram/webhook"}
        })
      end)

      assert {:ok, :unchanged} =
               Telegram.register_webhook("https://a1b2c3.ngrok-free.app/telegram/webhook")
    end

    test "reports a failure reading what is registered" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "Unauthorized"})
      end)

      assert {:error, {:telegram_error, "Unauthorized"}} =
               Telegram.register_webhook("https://example.com/telegram/webhook")
    end

    test "reports a failure setting the webhook" do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => ""}})

          "/bottest_telegram_bot_token/setWebhook" ->
            Req.Test.json(conn, %{"ok" => false, "description" => "bad webhook: HTTPS required"})
        end
      end)

      assert {:error, {:telegram_error, "bad webhook: HTTPS required"}} =
               Telegram.register_webhook("http://example.com/telegram/webhook")
    end

    test "reports a transport error" do
      Req.Test.stub(Telegram, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Telegram.register_webhook("https://example.com/telegram/webhook")
    end

    test "reports an answer it does not recognise" do
      Req.Test.stub(Telegram, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:error, :unexpected_response} =
               Telegram.register_webhook("https://example.com/telegram/webhook")
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
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :webhook_secret))

      assert :ok = Telegram.authenticate(conn(:post, "/telegram/webhook", ""))
    end
  end

  describe "configuration" do
    test "says what is missing, and where to set it, when the token is not configured" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :bot_token))

      assert_raise RuntimeError, ~r/no bot_token configured for ChatAgent.Channel.Telegram/, fn ->
        Telegram.send_message(123_456, "Hello")
      end
    end
  end

  describe "reference/0" do
    test "names the identifiers and where they are documented" do
      reference = Telegram.reference()

      assert reference.url =~ "core.telegram.org"
      assert {"chat.id", _} = Enum.find(reference.fields, &match?({"chat.id", _}, &1))
      assert {"from.id", _} = Enum.find(reference.fields, &match?({"from.id", _}, &1))
      assert {"update_id", _} = Enum.find(reference.fields, &match?({"update_id", _}, &1))
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
