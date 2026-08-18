defmodule ChatAgentWeb.Logger do
  @moduledoc """
  Per-route request logging for `Plug.Telemetry`, wired up in
  `ChatAgentWeb.Endpoint`.

  Health probes arrive every few seconds and each one would otherwise write two
  lines to the log, drowning out the requests worth reading and costing money
  wherever logs are billed by volume. So `/health` is silent unless
  `:healthcheck_logging` is switched on, which is what you do when a probe is
  failing and you need to see it arrive. Every other route logs as usual.
  """

  alias Plug.Conn

  @doc """
  Decide the level to log a request at, or `false` to log nothing.
  """
  @spec log(conn :: Conn.t()) :: Logger.level() | false
  def log(%Conn{path_info: ["health"]}) do
    if Application.get_env(:chat_agent, :healthcheck_logging, false) do
      :info
    else
      false
    end
  end

  def log(%Conn{}), do: :info
end
