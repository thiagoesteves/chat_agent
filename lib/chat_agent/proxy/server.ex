defmodule ChatAgent.Proxy.Server do

  @behaviour :gen_statem


  # This machine state will handle the states for the proxy connection
  # the main idea is to connect using the ngrok or other providers, the adater 
  # will implement the functions like authenticate, connect/run
  # but here we will have state like authenticating, setup (waiting for checking the local path), running and
  # in case of a failure, it then goes back to the whole cycle, with a backoff mechanism for a delay retry.
  # This is meant to run only when in dev, maybe because you want it to be local in your machine, if deployed in prod
  # the real path would come from Phoenix, it is not required.
end