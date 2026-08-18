defmodule ChatAgentWeb.Router do
  use ChatAgentWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatAgentWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChatAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/webhook", ChatAgentWeb do
    pipe_through :api

    get "/", WhatsappController, :verify
    post "/", WhatsappController, :receive
  end

  scope "/telegram/webhook", ChatAgentWeb do
    pipe_through :api

    post "/", TelegramController, :receive
  end
end
