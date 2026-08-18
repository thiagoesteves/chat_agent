defmodule ChatAgentWeb.Router do
  use ChatAgentWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatAgentWeb.Layouts, :root}
    plug :protect_from_forgery
    # default.css paints a texture from a data: URI, which default-src alone
    # blocks. The LiveView websocket is same origin, so 'self' already covers it.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'self'; img-src 'self' data:"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChatAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/channels", ChannelLive
  end

  # One scope per channel, carrying its channel in the route's assigns so no
  # path segment is ever turned into an atom. Only the verbs each provider
  # actually uses are exposed: WhatsApp performs a GET subscription handshake,
  # Telegram does not.
  scope "/whatsapp/webhook", ChatAgentWeb do
    pipe_through :api

    get "/", WebhookController, :verify, assigns: %{channel: :whatsapp}
    post "/", WebhookController, :receive, assigns: %{channel: :whatsapp}
  end

  scope "/telegram/webhook", ChatAgentWeb do
    pipe_through :api

    post "/", WebhookController, :receive, assigns: %{channel: :telegram}
  end
end
