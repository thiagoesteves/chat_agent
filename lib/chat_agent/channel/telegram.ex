defmodule ChatAgent.Channel.Telegram do
  @moduledoc """
  Telegram channel, spoken over the Telegram Bot API.

  Inbound, it receives a whole update object, which is the unit the Telegram
  webhook posts. Outbound, it posts text messages to the Bot API.
  """

  @behaviour ChatAgent.Channel.Adapter

  alias ChatAgent.Channel.Message

  require Logger

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def reference do
    %{
      url: "https://core.telegram.org/bots/api#message",
      fields: [
        {"chat.id",
         "The conversation, and the value sendMessage takes to reply. Positive for a " <>
           "private chat, where it equals the user's own id, negative for a group or channel."},
        {"from.id",
         "Who sent the message. Equal to chat.id in a private chat, but a person inside " <>
           "the group otherwise. Absent on channel posts."},
        {"update_id",
         "The webhook delivery, not the message. Per bot and sequential, which is what " <>
           "makes it useful for ignoring a repeated delivery, though it restarts from a " <>
           "random number after a week with no updates."}
      ]
    }
  end

  @impl true
  def handle_message(
        %{
          "message" =>
            %{
              "chat" => %{"id" => chat_id},
              "text" => text
            } = message
        } = update
      ) do
    # `from` names the person, `chat` names the conversation. They agree in a
    # private chat, where the chat id is the user's own id, and diverge in a
    # group, so a reply must use the chat.
    from_id = get_in(message, ["from", "id"])

    Logger.info(%{
      what: "telegram_message_received",
      chat_id: chat_id,
      from_id: from_id,
      text: text,
      update_id: update["update_id"]
    })

    {:ok,
     Message.new(
       id: to_string(update["update_id"]),
       sender: to_string(from_id || chat_id),
       conversation: to_string(chat_id),
       identifiers: [
         {"chat.id", chat_id},
         {"from.id", from_id},
         {"update_id", update["update_id"]}
       ],
       text: text
     )}
  end

  def handle_message(update) do
    Logger.info(%{
      what: "telegram_update_received",
      update: update
    })

    :ok
  end

  @impl true
  def authenticate(conn) do
    case Application.get_env(:chat_agent, :telegram_webhook_secret) do
      nil ->
        :ok

      expected ->
        if Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") == [expected] do
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  @impl true
  def inbound_messages(%{"update_id" => _} = update), do: {:ok, [update]}
  def inbound_messages(_params), do: {:error, :bad_request}

  @impl true
  def verify_subscription(_params) do
    # The Bot API sets its webhook over the API and performs no handshake.
    {:error, :not_found}
  end

  @impl true
  def register_webhook(url) do
    case current_webhook_url() do
      {:ok, ^url} ->
        {:ok, :unchanged}

      {:ok, _other} ->
        set_webhook(url)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def send_message(chat_id, body) do
    payload = %{
      chat_id: chat_id,
      text: body
    }

    "sendMessage"
    |> api_url()
    |> Req.post(request_options(json: payload))
    |> interpret_response()
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # What the Bot API currently calls, which is empty when no webhook is set.
  defp current_webhook_url do
    # Registration is retried by the caller with a backoff (see
    # `ChatAgent.Tunnel.Server`), so Req retrying underneath it only delays
    # that, and holds up whoever asked in the meantime.
    "getWebhookInfo"
    |> api_url()
    |> Req.get(request_options(retry: false))
    |> case do
      {:ok, %Req.Response{body: %{"ok" => true, "result" => result}}} ->
        {:ok, result["url"] || ""}

      other ->
        registration_error(other)
    end
  end

  # The secret token is sent with the URL, since the Bot API takes both in the
  # same call. It is not reported back by `getWebhookInfo`, so changing the
  # secret alone leaves the registered webhook looking unchanged: set it again
  # by hand after changing `TELEGRAM_WEBHOOK_SECRET`.
  defp set_webhook(url) do
    payload =
      case Application.get_env(:chat_agent, :telegram_webhook_secret) do
        nil -> %{url: url}
        secret -> %{url: url, secret_token: secret}
      end

    Logger.info(%{what: "telegram_webhook_registering", url: url})

    "setWebhook"
    |> api_url()
    |> Req.post(request_options(json: payload, retry: false))
    |> case do
      {:ok, %Req.Response{body: %{"ok" => true}}} -> {:ok, :registered}
      other -> registration_error(other)
    end
  end

  # Registration reports its own outcome, so a response that `interpret_response/1`
  # would call a success is a shape this did not expect rather than one.
  defp registration_error(response) do
    case interpret_response(response) do
      :ok -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_url(method),
    do: "https://api.telegram.org/bot#{get_config!(:telegram_bot_token)}/#{method}"

  defp request_options(options) do
    options
    |> Keyword.put_new(:headers, content_type: "application/json")
    |> Keyword.merge(Application.get_env(:chat_agent, :telegram_req_options, []))
  end

  # The Bot API answers 200 with `"ok" => false` for logical failures, so the
  # body decides the outcome rather than the status alone.
  defp interpret_response({:ok, %Req.Response{body: %{"ok" => true}}}), do: :ok

  defp interpret_response({:ok, %Req.Response{body: %{"description" => description}}}),
    do: {:error, {:telegram_error, description}}

  defp interpret_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_error, status}}

  defp interpret_response({:error, exception}), do: {:error, exception}

  defp get_config!(key), do: Application.fetch_env!(:chat_agent, key)
end
