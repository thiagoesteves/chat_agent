defmodule ChatAgent.Channel.Token do
  @moduledoc """
  The secret a webhook URL carries, and what tells a real delivery from anyone
  else who found the URL.

  A webhook is reachable by whoever can reach the internet, so the URL is the
  whole of its authentication unless something else is added. Services do not
  agree on what that something else is: Telegram sends back a header it was
  given, Meta signs the body, and a third service may do neither. What every
  one of them does do is call the URL it was handed, exactly as handed, which
  makes the URL the one place a secret can be put that works for all of them:

      https://example.ngrok-free.app/telegram/webhook?token=Ck1s...

  It rides as a query parameter rather than a path segment on purpose.
  `Plug.Telemetry` and Phoenix's logger write `conn.request_path`, which stops
  at the `?`, so the token stays out of every request log line. A secret path
  segment would be written to the log on each delivery instead.

  ## Where the value comes from

  A configured token is used as it stands, which is what a deployment behind a
  fixed name needs:

      config :chat_agent, ChatAgent.Channel.Token,
        telegram: "...",
        whatsapp: "..."

  These are keyed by channel rather than kept with the rest of a channel's
  configuration under its module, because a token is not something its service
  knows about: Telegram is handed a URL, not a token, and what guards that URL
  is this application's business alone. Keeping it here also means it belongs
  to the route rather than to whichever module currently serves the route.

  With none configured, one is generated for the channel when the application
  starts and kept for the life of the node. That is the right default for a
  development machine, where `ChatAgent.Tunnel` opens a new public URL on every
  start and re-registers each channel against it anyway: a token that changes
  with the URL that carries it costs nothing and is never written down.

  It is the wrong default behind a static `PUBLIC_URL`, where nothing
  re-registers and the service goes on calling the URL it was last given. So
  that case is warned about at startup rather than generated for silently: see
  `install/0`.
  """

  alias ChatAgent.Channel

  require Logger

  # 32 bytes of randomness, which is the size of the key it stands in for, and
  # url-safe so it survives being a query parameter unescaped.
  @bytes 32

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Settle a token for every configured channel.

  Called once from `ChatAgent.Application`, before anything can serve a request
  or register a URL, so that `for/1` answers the same value for the life of the
  node no matter who asks first or from which process.

  A channel with a configured token keeps it. A channel without one is given a
  generated token, and a generated token behind a static public URL is warned
  about: nothing re-registers that URL, so the service is still calling the
  token this node has just replaced.
  """
  @spec install() :: :ok
  def install do
    for {channel, _module} <- Channel.list(), is_nil(configured(channel)) do
      :persistent_term.put(key(channel), generate())

      if static_url?() do
        Logger.warning(%{
          what: "webhook_token_generated",
          channel: channel,
          detail:
            "No :webhook_token configured and the public URL is static, so nothing will " <>
              "re-register it. Deliveries to the previously registered URL will be refused " <>
              "until the webhook is registered again. Set a token to keep it across restarts."
        })
      end
    end

    :ok
  end

  @doc """
  The token `channel`'s webhook URL carries.

  Named `for_channel` rather than `for`, which is a special form: a function of
  that name can never be called unqualified, and reads as a comprehension
  wherever it appears. `ChatAgent.Accounts.Scope.for_user/1` is named the same
  way.

  ## Examples

      iex> ChatAgent.Channel.Token.for_channel(:telegram)
      "test_telegram_webhook_token"
  """
  @spec for_channel(channel :: Channel.channel()) :: String.t()
  def for_channel(channel) do
    configured(channel) || :persistent_term.get(key(channel), nil) || generate_and_keep(channel)
  end

  @doc """
  Whether `presented` is the token `channel`'s webhook URL was published with.

  Compared in constant time, since a comparison that stops at the first wrong
  byte tells whoever is guessing how much of the guess was right.

  ## Examples

      iex> ChatAgent.Channel.Token.valid?(:telegram, "test_telegram_webhook_token")
      true

      iex> ChatAgent.Channel.Token.valid?(:telegram, "wrong")
      false

      iex> ChatAgent.Channel.Token.valid?(:telegram, nil)
      false
  """
  @spec valid?(channel :: Channel.channel(), presented :: String.t() | nil) :: boolean()
  def valid?(_channel, nil), do: false

  def valid?(channel, presented) when is_binary(presented) do
    Plug.Crypto.secure_compare(for_channel(channel), presented)
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp configured(channel) do
    :chat_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(channel)
  end

  # `install/0` settles every configured channel before a request can arrive,
  # so reaching here means the channel appeared after startup, which is a test
  # rearranging configuration rather than anything that serves traffic.
  defp generate_and_keep(channel) do
    token = generate()
    :persistent_term.put(key(channel), token)

    token
  end

  defp generate, do: @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp static_url?, do: not is_nil(ChatAgent.Tunnel.config()[:url])

  defp key(channel), do: {__MODULE__, channel}
end
