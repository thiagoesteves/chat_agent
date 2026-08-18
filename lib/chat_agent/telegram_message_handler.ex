defmodule ChatAgent.TelegramMessageHandler do
  @moduledoc """
  Processes incoming Telegram messages.
  """

  require Logger

  def handle(
        %{
          "message" => %{
            "chat" => %{"id" => chat_id},
            "text" => text
          }
        } = update
      ) do
    Logger.info(%{
      what: "telegram_message_received",
      chat_id: chat_id,
      text: text,
      update_id: update["update_id"]
    })

    :ok
  end

  def handle(update) do
    Logger.info(%{
      what: "telegram_update_received",
      update: update
    })

    :ok
  end
end
