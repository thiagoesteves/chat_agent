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
        ChatAgent.Repo,
        # Every command run for its output gets a process of its own, started
        # here, so a run belongs to the supervision tree rather than to
        # whoever asked for it.
        {DynamicSupervisor, name: ChatAgent.Commander.RunnerSupervisor, strategy: :one_for_one},
        # Start to serve requests, typically the last entry
        ChatAgentWeb.Endpoint
      ] ++ assistant() ++ tunnel()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ChatAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `working_dir` belongs to an assistant, and `working_dir_root` to the
  # sessions that may choose one, which puts two similar names in two places.
  # Setting the root on the assistant is silent otherwise: nothing reads it,
  # and every --work-dir is refused with no reason given.
  defp warn_about_misplaced_root do
    Enum.each(ChatAgent.Assistant.list(), fn {name, module} ->
      if Application.get_env(:chat_agent, module, [])[:working_dir_root] do
        Logger.warning(%{
          what: "assistant_working_dir_root_misplaced",
          assistant: name,
          reason: "set :working_dir_root under ChatAgent.Assistant, not under #{inspect(module)}"
        })
      end
    end)
  end

  # A router with no password lets nobody in, and one with no assistant has
  # nothing to answer with. Either way there is no work, so it is not started
  # and the reason is said once at boot rather than guessed at later.
  defp assistant do
    warn_about_misplaced_root()

    cond do
      ChatAgent.Assistant.enabled?() ->
        [{ChatAgent.Assistant.Supervisor, []}]

      ChatAgent.Assistant.list() == [] ->
        []

      true ->
        Logger.info(%{
          what: "assistant_router_not_started",
          reason: "no password configured, so no conversation could be answered"
        })

        []
    end
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
