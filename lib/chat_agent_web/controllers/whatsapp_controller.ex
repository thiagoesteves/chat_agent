defmodule ChatAgentWeb.WhatsappController do
  use ChatAgentWeb, :controller

  def verify(conn, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => token,
        "hub.challenge" => challenge
      }) do
    if token == expected_verify_token() do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, challenge)
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  def verify(conn, _params) do
    send_resp(conn, 400, "Bad Request")
  end

  def receive(conn, %{"object" => "whatsapp_business_account", "entry" => entries}) do
    Enum.each(entries, &handle_entry/1)

    send_resp(conn, 200, "OK")
  end

  def receive(conn, _params) do
    send_resp(conn, 404, "Not Found")
  end

  defp handle_entry(%{"changes" => changes}) do
    Enum.each(changes, &handle_change/1)
  end

  defp handle_entry(_entry), do: :ok

  defp handle_change(%{"value" => %{"messages" => messages}}) do
    Enum.each(messages, &ChatAgent.Channel.handle_message(:whatsapp, &1))
  end

  defp handle_change(%{"value" => %{"statuses" => _statuses}}) do
    :ok
  end

  defp handle_change(_change), do: :ok

  defp expected_verify_token do
    Application.get_env(:chat_agent, :whatsapp_verify_token)
  end
end
