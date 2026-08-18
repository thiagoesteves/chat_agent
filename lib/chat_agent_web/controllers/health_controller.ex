defmodule ChatAgentWeb.HealthController do
  @moduledoc """
  Liveness endpoint, at `/health`.

  It answers 200 with a JSON body as long as the endpoint is accepting
  requests, which is all a load balancer or orchestrator probe needs. The
  timestamp makes a cached or replayed response obvious.

  Probes run continuously, so this route's request logging is controlled
  separately by `ChatAgentWeb.Logger`.
  """

  use ChatAgentWeb, :controller

  @doc """
  Report that the endpoint is serving requests.
  """
  def health(conn, _params) do
    json(conn, %{status: "ok", timestamp: DateTime.utc_now()})
  end
end
