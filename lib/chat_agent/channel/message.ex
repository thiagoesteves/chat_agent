defmodule ChatAgent.Channel.Message do
  @moduledoc """
  A chat message received on a channel, in a shape every channel agrees on.

  Channel modules build one of these from their own payload, which is the only
  place that knows where a sender or a body lives in that service's format.
  `ChatAgent.Channel` stamps the `:channel` field when it broadcasts, so a
  channel module never has to know which key it was registered under.
  """

  @enforce_keys [:sender, :text, :received_at]
  defstruct [:channel, :id, :sender, :text, :received_at]

  @type t :: %__MODULE__{
          channel: atom() | nil,
          id: String.t() | nil,
          sender: String.t(),
          text: String.t(),
          received_at: DateTime.t()
        }

  @doc """
  Build a message, defaulting `:received_at` to now.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    struct!(__MODULE__, Keyword.put_new_lazy(fields, :received_at, &DateTime.utc_now/0))
  end
end
