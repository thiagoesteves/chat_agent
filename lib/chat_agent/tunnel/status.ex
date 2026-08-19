defmodule ChatAgent.Tunnel.Status do
  @moduledoc """
  What the tunnel is doing, and the URL it has opened.

  Broadcast on every state change (see `ChatAgent.Tunnel.subscribe/0`) and
  returned by `ChatAgent.Tunnel.status/0`.
  """

  @typedoc """
  The tunnel's state:

    * `:disabled` - no provider configured, so no tunnel is run
    * `:down` - a provider is configured but its server is not running
    * `:authenticating` - proving the agent's credentials
    * `:connecting` - the agent is running, its URL not reported yet
    * `:registering` - the URL is known, the channels are being told about it
    * `:connected` - the URL is open and every channel knows it
  """
  @type state ::
          :disabled | :down | :authenticating | :connecting | :registering | :connected

  @type t :: %__MODULE__{
          state: state(),
          url: String.t() | nil,
          provider: module() | nil,
          error: term(),
          webhooks: %{optional(atom()) => term()},
          since: DateTime.t() | nil
        }

  defstruct state: :disabled,
            url: nil,
            provider: nil,
            error: nil,
            webhooks: %{},
            since: nil
end
