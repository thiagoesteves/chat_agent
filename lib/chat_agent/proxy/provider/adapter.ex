defmodule ChatAgent.Proxy.Adapter do
  @moduledoc false

  @callback authenticate() :: boolean()

  @callback run_link() :: :ok

end
