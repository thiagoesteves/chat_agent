defmodule ChatAgent.Tunnel.Status do
  @moduledoc """
  What the tunnel is doing, and the URL it has opened.

  Broadcast on every state change (see `ChatAgent.Tunnel.subscribe/0`) and
  returned by `ChatAgent.Tunnel.status/0`.

  `:webhooks` and `:health` are the two halves of whether a channel is reachable
  and answer different questions: the first is what each service said when it
  was told where to call, the second is what each service says about how
  calling it has been going since.
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

  @typedoc """
  What each channel reported the last time its delivery was checked, keyed by
  channel: `{:ok, %ChatAgent.Channel.Health{}}` where the service says how it
  is going, `{:error, :not_supported}` where it does not say at all, and
  `{:error, reason}` where the check itself could not be made.

  Empty until the first check has answered, which is a URL that has only just
  been registered rather than one nothing is arriving on.
  """
  @type health :: %{optional(atom()) => {:ok, ChatAgent.Channel.Health.t()} | {:error, term()}}

  @type t :: %__MODULE__{
          state: state(),
          url: String.t() | nil,
          provider: module() | nil,
          error: term(),
          webhooks: %{optional(atom()) => term()},
          health: health(),
          since: DateTime.t() | nil
        }

  defstruct state: :disabled,
            url: nil,
            provider: nil,
            error: nil,
            webhooks: %{},
            health: %{},
            since: nil
end
