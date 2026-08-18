defmodule ChatAgentWeb.WebhookController do
  @moduledoc """
  One webhook endpoint per channel, at `/<channel>/webhook`.

  The channel is fixed by the route rather than read out of the body. That
  matters for more than tidiness: each service authenticates differently, so
  letting the body choose the channel would let the sender choose which
  authentication runs. The route decides it before the payload is trusted, and
  carries the channel in its assigns so no request data becomes an atom.

  Everything service specific lives in the channel module behind
  `ChatAgent.Channel.Adapter`, so this controller stays the same as channels
  are added, and a channel registered in configuration gets a working webhook
  URL without a router change.
  """

  use ChatAgentWeb, :controller

  alias ChatAgent.Channel

  @doc """
  Answer a provider's subscription handshake.
  """
  def verify(%{assigns: %{channel: channel}} = conn, params) do
    with {:ok, module} <- Channel.fetch(channel),
         {:ok, challenge} <- module.verify_subscription(params) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, challenge)
    else
      :error -> send_error(conn, :not_found)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  @doc """
  Take delivery of a webhook and hand each payload to its channel.
  """
  def receive(%{assigns: %{channel: channel}} = conn, params) do
    with {:ok, module} <- Channel.fetch(channel),
         :ok <- module.authenticate(conn),
         {:ok, messages} <- module.inbound_messages(params) do
      Enum.each(messages, &Channel.handle_message(channel, &1))

      send_resp(conn, 200, "OK")
    else
      :error -> send_error(conn, :not_found)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, :forbidden), do: send_resp(conn, 403, "Forbidden")
  defp send_error(conn, :bad_request), do: send_resp(conn, 400, "Bad Request")
  defp send_error(conn, :not_found), do: send_resp(conn, 404, "Not Found")
end
