defmodule ChatAgent.Channel.Health do
  @moduledoc """
  Whether a chat service is managing to deliver to this app's webhook.

  Registering a webhook is a write, and a write only says where a service was
  told to call. This is the read that follows it: what the service believes it
  is calling, how much it has queued up because it could not, and what went
  wrong the last time it tried.

  The two answer different questions, and only the second one notices a URL
  that was registered correctly and stopped working afterwards: a tunnel whose
  edge moved and left the service dialling an address it resolved days ago, a
  secret that was rotated on one side only, a machine that went to sleep.

  Reported by `c:ChatAgent.Channel.Adapter.webhook_health/0`, polled by
  `ChatAgent.Tunnel.Server` while it has a URL open, and carried on
  `ChatAgent.Tunnel.Status` for anything watching the tunnel.

  ## Fields

    * `:state` - `:ok` when the service is delivering, `:failing` when it is
      not, `:unknown` when it does not say enough to tell. Which of those a
      given report means is the channel's judgement, since only it knows what
      its own service reports and what those reports are worth.
    * `:url` - the webhook URL the service says it calls, so a caller can
      compare it with the one it registered.
    * `:pending` - deliveries the service is holding because it could not hand
      them over, where it reports such a thing.
    * `:last_error` - what the service said went wrong on its last attempt,
      already in a form worth showing a person.
    * `:last_error_at` - when that attempt was. Services report this as a
      sticky value that outlives the failure it describes, so its age is what
      makes it worth acting on rather than its presence.
    * `:checked_at` - when this report was read, which is what makes a stale
      one recognisable as stale.
    * `:details` - anything else the service reported that is worth showing but
      not worth a field of its own.
  """

  @type state :: :ok | :failing | :unknown

  @type t :: %__MODULE__{
          state: state(),
          url: String.t() | nil,
          pending: non_neg_integer(),
          last_error: String.t() | nil,
          last_error_at: DateTime.t() | nil,
          checked_at: DateTime.t() | nil,
          details: %{optional(String.t()) => term()}
        }

  defstruct state: :unknown,
            url: nil,
            pending: 0,
            last_error: nil,
            last_error_at: nil,
            checked_at: nil,
            details: %{}

  @doc """
  Whether this report says the service is failing to deliver.

  ## Examples

      iex> ChatAgent.Channel.Health.failing?(%ChatAgent.Channel.Health{state: :failing})
      true

      iex> ChatAgent.Channel.Health.failing?(%ChatAgent.Channel.Health{state: :ok})
      false
  """
  @spec failing?(health :: t()) :: boolean()
  def failing?(%__MODULE__{state: state}), do: state == :failing
end
