defmodule ChatAgent.Commander.Adapter do
  @moduledoc """
  Behaviour that defines the Operational system adapter callback
  """

  @typedoc """
  A command to run.

  A string is handed to a shell, which is what a provider's own command line
  wants. A list is an executable and its arguments, run with no shell at all,
  which is what anything carrying text from a stranger must use: metacharacters
  in an argument stay data rather than becoming syntax.
  """
  @type command :: String.t() | [String.t()]

  @callback run_link(command(), list()) ::
              {:ok, any()} | {:ok, pid(), integer()} | {:error, any()}
  @callback run(command(), list()) ::
              {:ok, any()} | {:ok, pid(), integer()} | {:error, any()}
  @callback stop(integer()) :: :ok | {:error, any()}
  @callback send(integer(), String.t()) :: :ok
  @callback os_type() :: {:unix | :win32, atom()}
end
