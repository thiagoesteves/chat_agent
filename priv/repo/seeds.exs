# Seed the database with the default accounts configured under :repo_seeds.
#
#     mix run priv/repo/seeds.exs
#
# Each account is a map of exactly what an account needs, so a key that is
# misspelled is a failure with a message rather than an account that silently
# never appears:
#
#     config :chat_agent, :repo_seeds,
#       default_user: %{email: "admin@example.com", password: "..."}
#
#     or, for more than one:
#
#     config :chat_agent, :repo_seeds,
#       default_users: [
#         %{email: "admin@example.com", password: "..."},
#         %{email: "someone@example.com", password: "..."}
#       ]
#
# An empty map means no default account, which is the default: an account
# everybody knows the password of is worse than no account at all.

alias ChatAgent.Accounts.User
alias ChatAgent.Repo

seeds = Application.get_env(:chat_agent, :repo_seeds, [])

accounts =
  case Keyword.get(seeds, :default_user) do
    nil -> []
    account -> [account]
  end ++ Keyword.get(seeds, :default_users, [])

for account <- accounts, account != %{} do
  {email, password} =
    case account do
      %{email: email, password: password} when is_binary(email) and is_binary(password) ->
        {email, password}

      other ->
        raise """
        invalid :repo_seeds account: #{inspect(other)}

        Each account is a map with an email and a password:

            config :chat_agent, :repo_seeds,
              default_user: %{email: "admin@example.com", password: "..."}
        """
    end

  unless Repo.get_by(User, email: email) do
    %User{
      email: email,
      hashed_password: Pbkdf2.hash_pwd_salt(password),
      confirmed_at: DateTime.utc_now(:second)
    }
    |> Repo.insert!()
  end
end
