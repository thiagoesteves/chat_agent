defmodule ChatAgentWeb.Plugs.WebhookToken do
  @moduledoc """
  Require the token a channel's webhook URL was published with.

  A webhook is on the public internet, and a service proves itself in whatever
  way that service happens to support, which is not the same way twice and for
  some is not at all. This is the guard that does not depend on any of that:
  the URL each service was handed carries a secret (see
  `ChatAgent.Channel.Token`), and a request that arrives without it is refused
  before the body is looked at.

  It runs per channel, because the channel is fixed by the route rather than
  read out of the body, and each channel has its own token:

      scope "/telegram/webhook", ChatAgentWeb do
        pipe_through :api
        plug ChatAgentWeb.Plugs.WebhookToken, channel: :telegram

        post "/", TelegramController, :handle_webhook
      end

  A channel-specific check a service does support is worth keeping on top of
  this rather than instead of it, so this replaces nothing: Telegram still
  checks its secret header in `ChatAgent.Channel.Telegram.authenticate/1`.

  A refusal answers 403 with no detail. What is worth saying about it is said
  in the log, as `webhook_token_rejected`, and never includes the token that
  was presented.

  On the way through, the token is taken back out of the request. Phoenix
  merges the query string into `conn.params`, so leaving it there would hand a
  secret to the channel as though the service had sent it, and put it wherever
  that payload is later written down.
  """

  @behaviour Plug

  alias ChatAgent.Channel.Token

  require Logger

  @impl true
  def init(options), do: Keyword.fetch!(options, :channel)

  @impl true
  def call(conn, channel) do
    conn = Plug.Conn.fetch_query_params(conn)

    if Token.valid?(channel, conn.query_params["token"]) do
      %{
        conn
        | query_params: Map.delete(conn.query_params, "token"),
          params: Map.delete(conn.params, "token")
      }
    else
      Logger.warning(%{
        what: "webhook_token_rejected",
        channel: channel,
        method: conn.method,
        # Whoever is on the other end of the connection, which behind a tunnel
        # or a proxy is that rather than the caller. Worth having anyway: it is
        # the only thing about the request that the caller does not choose.
        remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
      })

      conn
      |> Plug.Conn.send_resp(403, "Forbidden")
      |> Plug.Conn.halt()
    end
  end
end
