defmodule ChatAgent.Channel.TelegramTest do
  use ExUnit.Case, async: true

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
      assert parsed.text == "Hello"
      assert %DateTime{} = parsed.received_at
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
end
