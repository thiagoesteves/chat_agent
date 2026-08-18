defmodule ChatAgent.MessageHandlerTest do
  use ExUnit.Case, async: true

  alias ChatAgent.MessageHandler

  test "handle/1 processes a text message" do
    message = %{
      "from" => "1234567890",
      "id" => "msg_123",
      "text" => %{"body" => "Hello"}
    }

    assert :ok = MessageHandler.handle(message)
  end

  test "handle/1 processes an unknown event" do
    assert :ok = MessageHandler.handle(%{"statuses" => [%{"id" => "msg_123"}]})
  end
end
