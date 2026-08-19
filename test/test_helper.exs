# Mock for `ChatAgent.Channel.Adapter`, used to verify what the routing facade
# and the webhook controllers hand to a channel. Mox checks the mock against
# the behaviour, so a callback change breaks these tests at compile time.
Mox.defmock(ChatAgent.ChannelMock, for: ChatAgent.Channel.Adapter)

# Mock for `ChatAgent.Commander.Adapter`. Every operating system call a tunnel
# provider makes goes through it, so a test can assert on the command without
# running anything.
Mox.defmock(ChatAgent.CommanderMock, for: ChatAgent.Commander.Adapter)

# Mock for `ChatAgent.Tunnel.Provider.Adapter`, so the tunnel state machine can
# be driven through every state without a tunnelling service.
Mox.defmock(ChatAgent.TunnelProviderMock, for: ChatAgent.Tunnel.Provider.Adapter)

ExUnit.start()
