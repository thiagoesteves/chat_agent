defmodule ChatAgent.Assistant.Supervisor do
  @moduledoc """
  Starts the router, and the supervisor its sessions are started under.

  Sessions are dynamic because conversations are: one arrives when somebody
  authenticates and ends when they stop, sit idle, or say so. Keeping them
  under their own supervisor means a session that fails takes down the
  conversation it was holding and nothing else.
  """

  use Supervisor

  @spec start_link(options :: keyword()) :: Supervisor.on_start()
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    children = [
      {DynamicSupervisor, name: ChatAgent.Assistant.SessionSupervisor, strategy: :one_for_one},
      {ChatAgent.Assistant.Router, options}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
