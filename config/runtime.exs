import Config

config :chat_agent,
  healthcheck_logging: System.get_env("HEALTHCHECK_LOGGING") == "true"

# Each channel's credentials, under that channel's own module. As everywhere
# else in this file, a key is set only when its variable is there, so nothing
# here overwrites config/<env>.override.exs with a nil.
if whatsapp_verify_token = System.get_env("WHATSAPP_VERIFY_TOKEN") do
  config :chat_agent, ChatAgent.Channel.Whatsapp, verify_token: whatsapp_verify_token
end

if whatsapp_access_token = System.get_env("WHATSAPP_ACCESS_TOKEN") do
  config :chat_agent, ChatAgent.Channel.Whatsapp, access_token: whatsapp_access_token
end

if whatsapp_phone_number_id = System.get_env("WHATSAPP_PHONE_NUMBER_ID") do
  config :chat_agent, ChatAgent.Channel.Whatsapp, phone_number_id: whatsapp_phone_number_id
end

if whatsapp_api_version = System.get_env("WHATSAPP_API_VERSION") do
  config :chat_agent, ChatAgent.Channel.Whatsapp, api_version: whatsapp_api_version
end

if telegram_bot_token = System.get_env("TELEGRAM_BOT_TOKEN") do
  config :chat_agent, ChatAgent.Channel.Telegram, bot_token: telegram_bot_token
end

if telegram_webhook_secret = System.get_env("TELEGRAM_WEBHOOK_SECRET") do
  config :chat_agent, ChatAgent.Channel.Telegram, webhook_secret: telegram_webhook_secret
end

# The password a conversation has to give before an assistant answers it.
# Unset means nobody is let in, which is the right default for something that
# listens to whoever can reach the bot.
if assistant_password = System.get_env("ASSISTANT_PASSWORD") do
  config :chat_agent, ChatAgent.Assistant, password: assistant_password
end

if working_dir_root = System.get_env("ASSISTANT_WORKING_DIR_ROOT") do
  config :chat_agent, ChatAgent.Assistant, working_dir_root: working_dir_root
end

if claude_executable = System.get_env("CLAUDE_EXECUTABLE") do
  config :chat_agent, ChatAgent.Assistant.Claude, executable: claude_executable
end

# Where sessions work, and the one place --work-dir may pick from.
if working_dir = System.get_env("ASSISTANT_WORKING_DIR") do
  config :chat_agent, ChatAgent.Assistant, working_dir: working_dir
end

# What the tool may do, as a comma separated list, granted to every
# conversation that knows the password. Nothing is granted without this.
if claude_allowed_tools = System.get_env("CLAUDE_ALLOWED_TOOLS") do
  config :chat_agent, ChatAgent.Assistant.Claude,
    allowed_tools:
      claude_allowed_tools |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Public ingress. Set TUNNEL_PROVIDER=ngrok or TUNNEL_PROVIDER=pinggy on a
# development machine to open a public URL for the chat services to call back
# on, which is what removes the need for a DNS name there. A deployment that has
# one sets PUBLIC_URL instead, or nothing at all: the production block below
# fills in its own host.
# Each key is set only when its variable is there, so this does not overwrite
# what config/<env>.override.exs configured with a nil.
tunnel_provider =
  case System.get_env("TUNNEL_PROVIDER") do
    "ngrok" -> ChatAgent.Tunnel.Provider.Ngrok
    "pinggy" -> ChatAgent.Tunnel.Provider.Pinggy
    _none -> nil
  end

if tunnel_provider do
  config :chat_agent, ChatAgent.Tunnel, provider: tunnel_provider
end

public_url = System.get_env("PUBLIC_URL")

if public_url do
  config :chat_agent, ChatAgent.Tunnel, url: public_url
end

if ngrok_authtoken = System.get_env("NGROK_AUTHTOKEN") do
  config :chat_agent, ChatAgent.Tunnel.Provider.Ngrok, authtoken: ngrok_authtoken
end

if ngrok_domain = System.get_env("NGROK_DOMAIN") do
  config :chat_agent, ChatAgent.Tunnel.Provider.Ngrok, domain: ngrok_domain
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/chat_agent start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :chat_agent, ChatAgentWeb.Endpoint, server: true
end

# The database path, set only when the variable is there. Development and test
# each name their own file in config/<env>.exs, and overwriting those from here
# would point the test suite at the development database.
if database_path = System.get_env("DATABASE_PATH") do
  config :chat_agent, ChatAgent.Repo, database: database_path
end

config :chat_agent, ChatAgentWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :chat_agent, ChatAgentWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/chat_agent_web/router\.ex$"E,
        ~r"lib/chat_agent_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :chat_agent, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # SQLite is a file, so a release needs somewhere to keep it. DATABASE_PATH,
  # read above, points it at a mounted volume.
  config :chat_agent, ChatAgent.Repo,
    database: System.get_env("DATABASE_PATH") || "priv/repo/chat_agent.db",
    pool_size: 1

  # Reachable over DNS, so the public URL is the endpoint's own host and no
  # tunnel is run. PUBLIC_URL, already set above, still wins when there is one.
  if is_nil(public_url) do
    config :chat_agent, ChatAgent.Tunnel, url: "https://#{host}"
  end

  config :chat_agent, ChatAgentWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :chat_agent, ChatAgentWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :chat_agent, ChatAgentWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
