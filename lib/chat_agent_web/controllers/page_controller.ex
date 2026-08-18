defmodule ChatAgentWeb.PageController do
  use ChatAgentWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
