defmodule ChatAgent.Channel.Adapter do
  @moduledoc """
  Behaviour that every chat channel must implement.

  A channel module owns everything about one chat service: the shape of the
  payloads it receives, and how it talks back to that service's API. The
  behaviour covers both directions:

    * `c:handle_message/1` takes what the channel webhook delivered, already
      unwrapped down to the smallest unit that channel talks in (a single
      message for WhatsApp, a single update for Telegram). When the payload is
      an actual chat message it returns it as a `ChatAgent.Channel.Message`,
      which `ChatAgent.Channel` broadcasts to subscribers.
    * `c:send_message/2` sends a text message back out on the same channel.
    * `c:register_webhook/2` points the service at the URL its webhook is
      served on, which is what makes a channel work behind a URL that changes
      (see `ChatAgent.Tunnel`).
    * `c:webhook_health/0` reads back whether that service is actually
      managing to deliver, which registration alone cannot say.

  ## Implementing a new channel

  1. Create a module under `ChatAgent.Channel` that declares
     `@behaviour ChatAgent.Channel.Adapter`.
  2. Implement `handle_message/1` and `send_message/2`. Return
     `{:ok, %ChatAgent.Channel.Message{}}` for a chat message worth showing,
     plain `:ok` for a payload with nothing to show (a delivery receipt, say),
     or `{:error, reason}` when the payload could not be processed or the
     message could not be delivered.
  3. Register it under a channel key in `config/config.exs` so
     `ChatAgent.Channel` can route to it.

  ### Example skeleton

      defmodule ChatAgent.Channel.MyChannel do
        @behaviour ChatAgent.Channel.Adapter

        require Logger

        @impl true
        def handle_message(%{"from" => from, "text" => text}) do
          Logger.info(%{what: "my_channel_message_received", text: text})

          {:ok, ChatAgent.Channel.Message.new(sender: from, text: text)}
        end

        def handle_message(_payload), do: :ok

        @impl true
        def send_message(recipient, body) do
          # post to the channel API and return :ok or {:error, reason}
        end

        @impl true
        def register_webhook(url, options) do
          # read what the service has registered, and only write when it
          # differs, or report {:error, :not_supported} when it has no API
          # for this at all. With `force: true` in options, write without
          # reading first.
        end

        @impl true
        def webhook_health do
          # ask the service what it thinks it is calling and how that is
          # going, or report {:error, :not_supported} when it does not say
        end
      end

  `handle_message/1` should accept any payload shape the channel can deliver.
  Webhooks send more than chat messages (delivery receipts, edits, reactions),
  and a function clause error there turns into a failed webhook response and a
  channel-side retry.

  `register_webhook/2` is asked again whenever a new public URL appears, so it
  should read before it writes: a service that already points at the URL wants
  `{:ok, :unchanged}`, not another write. That shortcut is what `force: true`
  turns off, for the case where the registration is known to be right and known
  not to be working.

  `send_message/2` should decide success by whatever its own API treats as
  success. That differs per service: an HTTP status for one, a field in a 200
  response body for another, which is exactly why the judgement belongs in the
  channel module rather than in a shared HTTP wrapper.
  """

  @typedoc """
  Who a message is addressed to, in whatever form the channel identifies a
  conversation: a phone number for WhatsApp, a chat id for Telegram.
  """
  @type recipient :: String.t() | integer()

  @doc """
  Process a single inbound payload from the channel.

  Called by `ChatAgent.Channel.handle_message/2` for the module registered
  under the requested channel. Return `{:ok, message}` for a chat message,
  which the caller broadcasts to subscribers, or `:ok` for a payload with
  nothing to show.
  """
  @callback handle_message(payload :: map()) ::
              :ok | {:ok, ChatAgent.Channel.Message.t()} | {:error, term()}

  @doc """
  Describe the identifiers this channel reports, and where they are documented.

  Used by the dashboard to explain a channel's vocabulary without the web layer
  needing to know anything about the service.
  """
  @callback reference() :: %{
              url: String.t(),
              fields: [{name :: String.t(), meaning :: String.t()}]
            }

  @doc """
  Authenticate an inbound webhook request.

  Each service proves itself differently, so the check belongs with the channel
  rather than in a shared plug: one signs the body, another sends a shared
  secret in a header.
  """
  @callback authenticate(conn :: Plug.Conn.t()) :: :ok | {:error, :forbidden}

  @doc """
  Pull the individual payloads out of a webhook body.

  Services wrap messages differently, one batching many behind an envelope and
  another posting a single update, so unwrapping belongs with the channel. Each
  returned payload is passed to `c:handle_message/1`.
  """
  @callback inbound_messages(params :: map()) ::
              {:ok, [map()]} | {:error, :bad_request | :not_found}

  @doc """
  Answer a subscription handshake.

  A channel whose provider performs no handshake returns `{:error, :not_found}`,
  which is what the endpoint answers.
  """
  @callback verify_subscription(params :: map()) ::
              {:ok, challenge :: String.t()} | {:error, :forbidden | :bad_request | :not_found}

  @doc """
  Point the service's webhook at `url`.

  Called when a public URL becomes available (see `ChatAgent.Tunnel`), which on
  a development machine is a new URL every time the tunnel is opened. A channel
  should read what the service currently has registered and answer `{:ok,
  :unchanged}` when it already matches, so restarting the app is not a write to
  someone else's API.

  A service whose callback URL cannot be set over its API answers `{:error,
  :not_supported}`, which is reported once rather than retried.

  ## Options

    * `:force` - write the registration without reading it back first, so a
      service that already points at `url` is told again. This is what repairs
      a registration that is right on paper and not working in practice: a
      service that resolved the URL once and cached the answer is only made to
      resolve it again by being told again.
  """
  @callback register_webhook(url :: String.t(), options :: keyword()) ::
              {:ok, :registered | :unchanged} | {:error, term()}

  @doc """
  Read back whether the service is managing to deliver to this app.

  Called on an interval while a public URL is open (see
  `ChatAgent.Tunnel.Server`), and the only check that catches a registration
  which was accepted and later stopped working.

  Deciding what counts as failing belongs here rather than in the caller: each
  service reports its own idea of delivery trouble, and what those numbers are
  worth is knowledge about that service. A service that reports nothing of the
  sort answers `{:error, :not_supported}`, and is not asked again while the
  URL stands.
  """
  @callback webhook_health() ::
              {:ok, ChatAgent.Channel.Health.t()} | {:error, :not_supported | term()}

  @doc """
  Send a plain text message out on the channel.

  Called by `ChatAgent.Channel.send_message/3` for the module registered under
  the requested channel.
  """
  @callback send_message(recipient :: recipient(), body :: String.t()) :: :ok | {:error, term()}
end
