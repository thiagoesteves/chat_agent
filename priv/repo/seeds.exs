# Seed the database with the default accounts configured under :repo_seeds.
#
#     mix run priv/repo/seeds.exs
#
# Example configuration in config/config.exs or config/runtime.exs:
#
#     config :chat_agent, :repo_seeds,
#       default_users: [
#         [username: "admin", password: "pass"]
#       ]
#
#     or for a single account:
#
#     config :chat_agent, :repo_seeds,
#       default_user: [username: "admin", password: "pass"]

alias ChatAgent.Accounts.User
alias ChatAgent.Repo

repo_seeds =
  :chat_agent
  |> Application.get_env(:repo_seeds, [])
  |> then(fn
    list when is_list(list) -> list
    _other -> []
  end)

default_users =
  Keyword.get(repo_seeds, :default_users, []) ++
    if user = Keyword.get(repo_seeds, :default_user), do: [user], else: []

for user <- default_users, user != [] and user != %{} do
  email = Keyword.get(user, :email) || Keyword.get(user, :username)
  password = Keyword.get(user, :password)

  if is_binary(email) and is_binary(password) do
    unless Repo.get_by(User, email: email) do
      %User{
        email: email,
        hashed_password: Pbkdf2.hash_pwd_salt(password),
        confirmed_at: DateTime.utc_now(:second)
      }
      |> Repo.insert!()
    end
  end
end
