import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

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

# No password, so the application starts no router: a test that wants one
# starts its own, under its own name.
config :chat_agent, ChatAgent.Assistant,
  default: :claude,
  session_timeout: :timer.minutes(5),
  history_limit: 4,
  adapters: [claude: ChatAgent.AssistantMock]

config :chat_agent, ChatAgent.Channel.Whatsapp,
  verify_token: "test_verify_token",
  access_token: "test_access_token",
  phone_number_id: "123456789",
  api_version: "v20.0",
  req_options: [plug: {Req.Test, ChatAgent.Channel.Whatsapp}]

config :chat_agent, ChatAgent.Channel.Telegram,
  bot_token: "test_telegram_bot_token",
  webhook_secret: "test_telegram_webhook_secret",
  req_options: [plug: {Req.Test, ChatAgent.Channel.Telegram}]

# SQLite takes one writer at a time, so a single pooled connection is what keeps
# concurrent `async: true` tests from colliding on it. Sandbox ownership then
# hands that connection to one test at a time; everything else still runs async.
config :chat_agent, ChatAgent.Repo,
  database: "priv/repo/test.sqlite3",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1
