defmodule ChatAgentWeb.TelegramController do
  @moduledoc """
  Telegram webhook, at `/telegram/webhook`.

  Everything specific to the Bot API, checking the shared secret header and
  recognising an update, lives in `ChatAgent.Channel.Telegram`. This controller
  only turns those results into responses.

  There is no verify action: the Bot API sets its webhook over the API and
  performs no handshake.
  """

  use ChatAgentWeb, :controller

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Telegram

  @channel :telegram

  @doc """
  Take delivery of an update and hand it to the channel.
  """
  def handle_webhook(conn, params) do
    with :ok <- Telegram.authenticate(conn),
         {:ok, updates} <- Telegram.inbound_messages(params) do
      Enum.each(updates, &Channel.handle_message(@channel, &1))

      send_resp(conn, 200, "OK")
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, :forbidden), do: send_resp(conn, 403, "Forbidden")
  defp send_error(conn, :bad_request), do: send_resp(conn, 400, "Bad Request")
end
