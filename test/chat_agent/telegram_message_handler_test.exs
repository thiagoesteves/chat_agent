defmodule ChatAgent.TelegramMessageHandlerTest do
  use ExUnit.Case, async: true

  alias ChatAgent.TelegramMessageHandler

  test "handle/1 processes a text message" do
    update = %{
      "update_id" => 1,
      "message" => %{
        "chat" => %{"id" => 123_456},
        "text" => "Hello"
      }
    }

    assert :ok = TelegramMessageHandler.handle(update)
  end

  test "handle/1 processes an unknown update" do
    assert :ok = TelegramMessageHandler.handle(%{"update_id" => 1})
  end
end
