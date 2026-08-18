defmodule ChatAgent.MessageHandler do
  @moduledoc """
  Processes incoming WhatsApp messages.
  """

  require Logger

  def handle(%{"from" => phone, "text" => %{"body" => body}} = message) do
    Logger.info(%{
      what: "whatsapp_message_received",
      from: phone,
      body: body,
      message_id: message["id"]
    })

    :ok
  end

  def handle(message) do
    Logger.info(%{
      what: "whatsapp_event_received",
      message: message
    })

    :ok
  end
end
