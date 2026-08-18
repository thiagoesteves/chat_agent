# Mock for `ChatAgent.Channel.Adapter`, used to verify what the routing facade
# and the webhook controllers hand to a channel. Mox checks the mock against
# the behaviour, so a callback change breaks these tests at compile time.
Mox.defmock(ChatAgent.ChannelMock, for: ChatAgent.Channel.Adapter)

ExUnit.start()
