defmodule ChatAgentWeb.Router do
  use ChatAgentWeb, :router

  import ChatAgentWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatAgentWeb.Layouts, :root}
    plug :fetch_current_scope_for_user
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

  # Public landing page.
  scope "/", ChatAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Protected dashboard.
  scope "/", ChatAgentWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_channels,
      on_mount: [{ChatAgentWeb.UserAuth, :require_authenticated}] do
      live "/channels", ChannelLive
    end
  end

  # Liveness probe. It sits outside the channel scopes because it belongs to no
  # channel, and it is unauthenticated so a load balancer can reach it.
  scope "/", ChatAgentWeb do
    pipe_through :api

    get "/health", HealthController, :health
  end

  # One scope per channel, all following the same "/<channel>/webhook" shape.
  # Only the verbs a provider actually uses are exposed: WhatsApp performs a
  # GET subscription handshake, Telegram does not.
  scope "/whatsapp/webhook", ChatAgentWeb do
    pipe_through :api

    get "/", WhatsappController, :verify
    post "/", WhatsappController, :handle_webhook
  end

  scope "/telegram/webhook", ChatAgentWeb do
    pipe_through :api

    post "/", TelegramController, :handle_webhook
  end

  ## Authentication routes

  scope "/", ChatAgentWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ChatAgentWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Authenticated user routes (settings).
  scope "/", ChatAgentWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ChatAgentWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end
end
