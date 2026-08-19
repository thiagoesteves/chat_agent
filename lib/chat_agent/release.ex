defmodule ChatAgent.Release do
  @moduledoc """
  The tasks a release has to be able to run without Mix.

  A release ships compiled code and no build tool, so `mix ecto.migrate` is not
  available where it matters most. These are the same tasks, callable from the
  release's own binary:

      bin/chat_agent eval "ChatAgent.Release.migrate()"
      bin/chat_agent eval "ChatAgent.Release.prepare_storage()"
      bin/chat_agent eval "ChatAgent.Release.rollback(ChatAgent.Repo, 20260819152520)"

  Run the migration before starting the application, not from inside it: a node
  that migrates on boot races every other node doing the same.
  """

  @app :chat_agent

  @doc """
  Bring every configured repository up to date.
  """
  @spec migrate() :: :ok
  def migrate do
    prepare_storage()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Make the directories the database files live in.

  SQLite is a file, and opening one creates it, but only inside a directory
  that exists. A release pointed at a fresh volume through `DATABASE_PATH` has
  no such directory, and would otherwise fail on the migration rather than on
  the thing that is actually missing.
  """
  @spec prepare_storage() :: :ok
  def prepare_storage do
    load_app()

    Enum.each(repos(), fn repo ->
      case Application.get_env(@app, repo)[:database] do
        nil -> :ok
        path -> path |> Path.dirname() |> File.mkdir_p!()
      end
    end)
  end

  @doc """
  Take one repository back to `version`.
  """
  @spec rollback(repo :: module(), version :: integer()) :: :ok
  def rollback(repo, version) do
    prepare_storage()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc """
  The repositories a release knows about.
  """
  @spec repos() :: [module()]
  def repos do
    load_app()

    Application.fetch_env!(@app, :ecto_repos)
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp load_app, do: Application.ensure_loaded(@app)
end
