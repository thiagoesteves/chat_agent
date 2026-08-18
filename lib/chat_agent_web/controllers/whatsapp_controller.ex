defmodule ChatAgentWeb.WhatsappController do
  @moduledoc """
  WhatsApp webhook, at `/whatsapp/webhook`.

  Everything specific to the Cloud API, proving a request came from Meta,
  unwrapping the entry/change envelope and answering the subscription
  handshake, lives in `ChatAgent.Channel.Whatsapp`. This controller only turns
  those results into responses.
  """

  use ChatAgentWeb, :controller

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Whatsapp

  @channel :whatsapp

  @doc """
  Answer the subscription handshake Meta performs when the webhook is set.
  """
  def verify(conn, params) do
    case Whatsapp.verify_subscription(params) do
      {:ok, challenge} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, challenge)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  @doc """
  Take delivery of a webhook and hand every message it carries to the channel.
  """
  def handle_webhook(conn, params) do
    with :ok <- Whatsapp.authenticate(conn),
         {:ok, messages} <- Whatsapp.inbound_messages(params) do
      Enum.each(messages, &Channel.handle_message(@channel, &1))

      send_resp(conn, 200, "OK")
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, :forbidden), do: send_resp(conn, 403, "Forbidden")
  defp send_error(conn, :bad_request), do: send_resp(conn, 400, "Bad Request")
  defp send_error(conn, :not_found), do: send_resp(conn, 404, "Not Found")
end
