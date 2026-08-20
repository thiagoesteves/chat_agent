defmodule ChatAgent.Repo do
  use Ecto.Repo,
    otp_app: :chat_agent,
    adapter: Ecto.Adapters.SQLite3
end
