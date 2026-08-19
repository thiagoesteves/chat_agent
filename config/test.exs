import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :chat_agent, ChatAgentWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NCQDACJPd2whU+DltArVV3kbe+p/gzM2ggUIrA/XTz6X9+0zwQBQDl5Q0i7cqOBu",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :chat_agent, ChatAgent.Commander, adapter: ChatAgent.CommanderMock

config :chat_agent,
  whatsapp_verify_token: "test_verify_token",
  whatsapp_access_token: "test_access_token",
  whatsapp_phone_number_id: "123456789",
  whatsapp_api_version: "v20.0",
  whatsapp_req_options: [plug: {Req.Test, ChatAgent.Channel.Whatsapp}],
  telegram_bot_token: "test_telegram_bot_token",
  telegram_webhook_secret: "test_telegram_webhook_secret",
  telegram_req_options: [plug: {Req.Test, ChatAgent.Channel.Telegram}]
