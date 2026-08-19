defmodule ChatAgent.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        ChatAgentWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:chat_agent, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ChatAgent.PubSub},
        # Start to serve requests, typically the last entry
        ChatAgentWeb.Endpoint
      ] ++ tunnel()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ChatAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The tunnel forwards to the endpoint, so it is started after it, and only
  # when there is a tunnel to run: a deployment reachable over DNS runs none.
  defp tunnel do
    config = ChatAgent.Tunnel.config()

    cond do
      ChatAgent.Tunnel.enabled?() ->
        [ChatAgent.Tunnel.Server]

      config[:provider] ->
        # Both were configured. The static URL is the one everything else
        # answers with, so running an agent would only open a second address
        # that nothing points at.
        Logger.info(%{
          what: "tunnel_not_started",
          reason: "a public URL is already configured",
          url: config[:url]
        })

        []

      true ->
        []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChatAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
