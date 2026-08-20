defmodule ChatAgent.ReleaseTest do
  # Not async: migrating touches the one database every other test shares.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ChatAgent.Release
  alias ChatAgent.Repo
  alias Ecto.Adapters.SQL.Sandbox

  describe "repos/0" do
    test "names what a release would migrate" do
      assert Release.repos() == [Repo]
    end
  end

  describe "prepare_storage/0" do
    test "makes the directory the database file lives in" do
      configured = Application.get_env(:chat_agent, Repo)
      on_exit(fn -> Application.put_env(:chat_agent, Repo, configured) end)

      fresh =
        Path.join([System.tmp_dir!(), "release_#{System.unique_integer([:positive])}", "db"])

      on_exit(fn -> File.rm_rf!(Path.dirname(fresh)) end)
      refute File.dir?(Path.dirname(fresh))

      Application.put_env(:chat_agent, Repo, Keyword.put(configured, :database, fresh))

      assert :ok = Release.prepare_storage()

      # A release pointed at a fresh volume has a path and no directory, and
      # would otherwise fail on the migration rather than on what is missing.
      assert File.dir?(Path.dirname(fresh))
    end

    test "does nothing for a repository configured with no database file" do
      configured = Application.get_env(:chat_agent, Repo)
      on_exit(fn -> Application.put_env(:chat_agent, Repo, configured) end)

      Application.put_env(:chat_agent, Repo, Keyword.delete(configured, :database))

      assert :ok = Release.prepare_storage()
    end
  end

  describe "migrate/0" do
    setup do
      # Migrations run on the repository's own connection, which the sandbox
      # owns in the test environment.
      :ok = Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})

      on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    end

    test "brings the database up to date, and stays quiet when it already is" do
      # A release that migrates twice, or migrates an already current database,
      # must not fail the second time: deployments repeat.
      #
      # The migrator loads the migration files, which the suite has already
      # loaded, and the compiler says so on stderr. That belongs to running
      # migrations twice in one VM rather than to anything under test.
      assert {:ok, _said} = with_io(:stderr, fn -> Release.migrate() end)
      assert {:ok, _said} = with_io(:stderr, fn -> Release.migrate() end)
    end

    test "takes a repository back, and forward again" do
      [version] =
        "priv/repo/migrations/*.exs"
        |> Path.wildcard()
        |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))

      assert {:ok, _said} = with_io(:stderr, fn -> Release.rollback(Repo, version) end)
      refute users_table?()

      # Going back is only useful if going forward again works, which is what a
      # release does after a bad deployment.
      assert {:ok, _said} = with_io(:stderr, fn -> Release.migrate() end)
      assert users_table?()
    end
  end

  defp users_table? do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'")

    rows != []
  end
end
