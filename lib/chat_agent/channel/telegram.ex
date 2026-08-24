defmodule ChatAgent.Channel.Telegram do
  @moduledoc """
  Telegram channel, spoken over the Telegram Bot API.

  Inbound, it receives a whole update object, which is the unit the Telegram
  webhook posts. Outbound, it posts text messages to the Bot API.

  ## Configuration

  This channel reads its own configuration, under its own module name:

      config :chat_agent, ChatAgent.Channel.Telegram,
        # The bot's token, from BotFather. Set from TELEGRAM_BOT_TOKEN.
        bot_token: nil,
        # Sent to Telegram when registering the webhook, and required back on
        # every delivery. Set from TELEGRAM_WEBHOOK_SECRET. With none set, any
        # request that reaches the webhook is accepted.
        webhook_secret: nil,
        # Passed to every Req call, which is what lets a test answer without a
        # network.
        req_options: [],
        # Directory where Telegram attachments are saved for the assistant to
        # read. Set from TELEGRAM_DOWNLOAD_DIR.
        download_dir: "/tmp/chat_agent/telegram"
  """

  @behaviour ChatAgent.Channel.Adapter

  alias ChatAgent.Channel
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
          "message" => %{"chat" => %{"id" => chat_id}} = message
        } = update
      ) do
    # `from` names the person, `chat` names the conversation. They agree in a
    # private chat, where the chat id is the user's own id, and diverge in a
    # group, so a reply must use the chat.
    from_id = get_in(message, ["from", "id"])

    case content(update, message, chat_id) do
      {:ok, text} ->
        Logger.info(%{
          what: "telegram_message_received",
          chat_id: chat_id,
          from_id: from_id,
          text: text,
          update_id: update["update_id"]
        })

        {:ok, build_message(update, chat_id, from_id, text)}

      # Nothing worth showing: a sticker, a location, a service message. The
      # clause below cannot be reached by calling this function again, since it
      # matches this one first, and calling it again is what looped forever.
      :ignore ->
        log_other(update)
    end
  end

  def handle_message(update), do: log_other(update)

  @impl true
  def authenticate(conn) do
    case config(:webhook_secret) do
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

  defp build_message(update, chat_id, from_id, text) do
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
    )
  end

  defp content(update, message, chat_id) do
    base = message["text"] || message["caption"]

    case attachment(message) do
      nil when is_binary(base) ->
        {:ok, base}

      nil ->
        :ignore

      # Downloading happens here, before `ChatAgent.Channel` has decided
      # whether it will talk to this conversation at all, so the list is asked
      # first: otherwise a stranger nobody listed can make this fetch and keep
      # twenty megabytes at a time, and nothing ever deletes it.
      attachment ->
        attachment_for(update, base, attachment, chat_id)
    end
  end

  defp attachment_for(update, base, attachment, chat_id) do
    if Channel.allowed_for?(__MODULE__, chat_id) do
      attachment_content(update["update_id"], base, attachment)
    else
      Logger.info(%{
        what: "telegram_attachment_ignored",
        chat_id: chat_id,
        reason: "conversation is not in :allowed_chat_ids"
      })

      # What was said still stands, and the facade drops the whole message a
      # moment later.
      if is_binary(base), do: {:ok, base}, else: :ignore
    end
  end

  defp attachment(message) do
    Enum.find_value(
      [
        {:document, message["document"]},
        {:photo, last_photo(message["photo"])},
        {:audio, message["audio"]},
        {:video, message["video"]},
        {:voice, message["voice"]},
        {:animation, message["animation"]}
      ],
      fn
        {kind, details} when is_map(details) -> Map.put(details, "kind", kind)
        # Anything else is a payload this does not recognise, and a webhook
        # that raises answers 500 and is retried for as long as the sender
        # cares to.
        {_kind, _details} -> nil
      end
    )
  end

  # Telegram sends a photo as its sizes, largest last. Anything else in that
  # field is not a photo.
  defp last_photo(sizes) when is_list(sizes), do: List.last(sizes)
  defp last_photo(_other), do: nil

  defp log_other(update) do
    Logger.info(%{what: "telegram_update_received", update: update})

    :ok
  end

  defp attachment_content(update_id, base, attachment) do
    case download_attachment(update_id, attachment) do
      {:ok, details} ->
        {:ok,
         [base, attachment_description(details)] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")}

      {:error, reason} ->
        Logger.warning(%{
          what: "telegram_file_download_failed",
          file_name: attachment["file_name"],
          reason: inspect(reason),
          update_id: update_id
        })

        {:ok,
         [base, "Telegram attachment could not be downloaded."]
         |> Enum.reject(&is_nil/1)
         |> Enum.join("\n\n")}
    end
  end

  defp download_attachment(update_id, attachment) do
    with {:ok, file_path} <- get_file(attachment["file_id"]),
         {:ok, body} <- download_file(file_path),
         destination = destination(update_id, attachment, file_path),
         :ok <- File.mkdir_p(download_dir()),
         :ok <- File.write(destination, body) do
      {:ok,
       %{
         path: destination,
         name: Path.basename(destination),
         mime_type: attachment["mime_type"] || "unknown",
         # What reached the disk, rather than what the payload said would.
         size: byte_size(body)
       }}
    end
  end

  defp get_file(file_id) do
    case Req.get(api_url("getFile"), request_options(json: %{file_id: file_id}, retry: false)) do
      {:ok, %Req.Response{body: %{"ok" => true, "result" => %{"file_path" => file_path}}}} ->
        {:ok, file_path}

      {:ok, %Req.Response{body: %{"description" => description}}} ->
        {:error, {:telegram_error, description}}

      other ->
        request_error(other)
    end
  end

  defp download_file(file_path) do
    # `raw: true` because this is a file rather than an API response: without
    # it Req decodes by content type, and a .json or .csv attachment comes back
    # as a map, which the guard below then reads as a failed download.
    case Req.get(file_url(file_path), request_options(retry: false, raw: true)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp destination(update_id, attachment, file_path) do
    filename = attachment["file_name"] || Path.basename(file_path)
    filename = safe_filename(filename, attachment["kind"])

    digest =
      :crypto.hash(:sha256, to_string(attachment["file_id"])) |> Base.encode16(case: :lower)

    Path.join(download_dir(), "#{update_id}-#{String.slice(digest, 0, 12)}-#{filename}")
  end

  defp safe_filename(filename, kind) do
    filename = filename |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

    if filename in ["", ".", ".."], do: "telegram_#{kind}", else: filename
  end

  defp attachment_description(details) do
    [
      "Telegram attachment downloaded.",
      "Name: #{details.name}",
      "MIME type: #{details.mime_type}",
      "Size: #{details.size} bytes",
      "Local path: #{details.path}"
    ]
    |> Enum.join("\n")
  end

  defp file_url(file_path),
    do: "https://api.telegram.org/file/bot#{config!(:bot_token)}/#{file_path}"

  # Read when it is needed, so what is configured is what is used: a path
  # frozen at compile time is the build machine's, not this one's.
  defp download_dir, do: config(:download_dir) || "/tmp/chat_agent/telegram"

  # A described failure is answered by the caller, which knows what it asked
  # for; what reaches here is a response that explains itself with a status, or
  # a request that never arrived.
  defp request_error({:ok, %Req.Response{status: status}}), do: {:error, {:http_error, status}}
  defp request_error({:error, exception}), do: {:error, exception}

  # What the Bot API currently calls, which is empty when no webhook is set.
  def current_webhook_url do
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
      case config(:webhook_secret) do
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
    do: "https://api.telegram.org/bot#{config!(:bot_token)}/#{method}"

  defp request_options(options) do
    options
    |> Keyword.put_new(:headers, content_type: "application/json")
    |> Keyword.merge(config(:req_options) || [])
  end

  # The Bot API answers 200 with `"ok" => false` for logical failures, so the
  # body decides the outcome rather than the status alone.
  defp interpret_response({:ok, %Req.Response{body: %{"ok" => true}}}), do: :ok

  defp interpret_response({:ok, %Req.Response{body: %{"description" => description}}}),
    do: {:error, {:telegram_error, description}}

  defp interpret_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_error, status}}

  defp interpret_response({:error, exception}), do: {:error, exception}

  # This channel's own configuration, under its module name, read at call time
  # so a change needs no recompile.
  defp config(key), do: Application.get_env(:chat_agent, __MODULE__, [])[key]

  defp config!(key) do
    config(key) ||
      raise """
      no #{key} configured for #{inspect(__MODULE__)}.

      Set it in config/runtime.exs from the environment, or in
      config/<env>.override.exs while developing:

          config :chat_agent, #{inspect(__MODULE__)}, #{key}: "..."
      """
  end
end
