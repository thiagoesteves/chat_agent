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
      end

  `handle_message/1` should accept any payload shape the channel can deliver.
  Webhooks send more than chat messages (delivery receipts, edits, reactions),
  and a function clause error there turns into a failed webhook response and a
  channel-side retry.

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
  Send a plain text message out on the channel.

  Called by `ChatAgent.Channel.send_message/3` for the module registered under
  the requested channel.
  """
  @callback send_message(recipient :: recipient(), body :: String.t()) :: :ok | {:error, term()}
end
