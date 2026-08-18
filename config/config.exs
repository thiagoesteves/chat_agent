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

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
