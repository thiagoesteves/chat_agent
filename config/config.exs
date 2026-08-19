# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :chat_agent,
  generators: [timestamp_type: :utc_datetime],
  # Health probes run continuously, so `/health` requests are not logged by
  # default. Set HEALTHCHECK_LOGGING=true to see them while debugging a probe.
  healthcheck_logging: false

# Maps each chat channel to the module that speaks it, in both directions.
# Every module implements `ChatAgent.Channel.Adapter`.
config :chat_agent, ChatAgent.Channel,
  adapters: [
    telegram: ChatAgent.Channel.Telegram,
    whatsapp: ChatAgent.Channel.Whatsapp
  ]

# Each channel reads its own configuration under its module name, the same way
# a tunnel provider does. Only defaults live here: everything secret is read
# from the environment in config/runtime.exs.
config :chat_agent, ChatAgent.Channel.Whatsapp, api_version: "v20.0"

# Public ingress. Without a provider no tunnel is run and the URL, if any,
# comes from the `:url` key: that is how a deployment behind DNS runs, and
# `TUNNEL_PROVIDER=ngrok` in config/runtime.exs is how a development machine
# gets a public URL without one. See `ChatAgent.Tunnel`.
config :chat_agent, ChatAgent.Tunnel,
  provider: nil,
  url: nil,
  port: nil,
  connect_timeout: :timer.seconds(30),
  max_backoff: :timer.minutes(1)

# Runs the operating system commands a tunnel provider needs. Swapped for a
# mock in tests, so nothing there reaches the machine.
config :chat_agent, ChatAgent.Commander, adapter: ChatAgent.Commander.Local

# Configure the endpoint
config :chat_agent, ChatAgentWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ChatAgentWeb.ErrorHTML, json: ChatAgentWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ChatAgent.PubSub,
  live_view: [signing_salt: "ic3Jld2Q"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  chat_agent: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  chat_agent: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# File used for configuration overrides and individual secrets.
# Set config on this file according to the desired MIX_ENV.
override_file = "#{config_env()}.override.exs"

if File.exists?("config/#{override_file}") or File.exists?("../../config/#{override_file}") do
  import_config override_file
end
