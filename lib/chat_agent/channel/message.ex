defmodule ChatAgent.Channel.Message do
  @moduledoc """
  A chat message received on a channel, in a shape every channel agrees on.

  Channel modules build one of these from their own payload, which is the only
  place that knows where a sender or a body lives in that service's format.

  `:sender` is who wrote the message and `:conversation` is where a reply goes.
  They are the same value on a service that only carries one to one chats, and
  different on one that carries groups, where the conversation is the group and
  the sender is a person in it.

  `:identifiers` are the raw values the service gave, under the names it uses
  for them. They are what the dashboard shows, and the names line up with the
  ones `c:ChatAgent.Channel.Adapter.reference/0` documents.

  A channel lists every identifier it might report and `new/1` drops the ones
  the payload had no value for, so a field the service did not send is absent
  rather than shown empty or filled in from somewhere else.
  `ChatAgent.Channel` stamps the `:channel` field when it broadcasts, so a
  channel module never has to know which key it was registered under.
  """

  @enforce_keys [:sender, :conversation, :text, :received_at]
  defstruct [:channel, :id, :sender, :conversation, :text, :received_at, identifiers: []]

  @type t :: %__MODULE__{
          channel: atom() | nil,
          id: String.t() | nil,
          sender: String.t(),
          conversation: String.t(),
          text: String.t(),
          received_at: DateTime.t(),
          identifiers: [{name :: String.t(), value :: String.t()}]
        }

  @doc """
  Build a message, defaulting `:received_at` to now.

  Identifiers without a value are dropped, and the rest are stringified, so a
  channel can list everything it might report without checking each one.

  ## Examples

      iex> message = ChatAgent.Channel.Message.new(
      ...>   sender: "1",
      ...>   conversation: "1",
      ...>   text: "Hello",
      ...>   identifiers: [{"chat.id", 1}, {"from.id", nil}]
      ...> )
      iex> message.identifiers
      [{"chat.id", "1"}]
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new_lazy(:received_at, &DateTime.utc_now/0)
    |> Keyword.replace_lazy(:identifiers, &reported/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp reported(identifiers) do
    for {name, value} <- identifiers, value not in [nil, ""], do: {name, to_string(value)}
  end
end
