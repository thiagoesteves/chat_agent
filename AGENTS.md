# ChatAgent - Agent Code Guide

## Project Overview

ChatAgent is a Phoenix application that receives chat messages from external messaging services over webhooks and sends replies back to them.
It currently speaks WhatsApp (Cloud API) and Telegram (Bot API).
There is no database: inbound messages are handled in process and broadcast over PubSub, and a LiveView dashboard shows them arriving.
Reaching those webhooks from the internet is `ChatAgent.Tunnel`'s job: in a deployment that is a DNS name, and on a development machine it is a tunnel agent (ngrok or Pinggy) run as an OS process.

Elixir requirement is `~> 1.19`.
The exact toolchain is pinned in `.tool-versions` (Erlang 28.5.0.4, Elixir 1.19.5-otp-28).

---

## Structure

```
lib/
  chat_agent/
    channel.ex              # ChatAgent.Channel, the routing facade
    channel/
      adapter.ex            # behaviour every channel implements
      message.ex            # normalised inbound message struct
      whatsapp.ex           # WhatsApp channel, both directions
      telegram.ex           # Telegram channel, both directions
    commander.ex            # ChatAgent.Commander, the OS facade
    commander/
      adapter.ex            # behaviour the OS binding implements
      local.ex              # erlexec binding, the only implementation
      runner.ex             # one command, in a process of its own
    assistant.ex            # ChatAgent.Assistant, the facade over what answers
    assistant/
      adapter.ex            # behaviour every assistant implements
      claude.ex             # the claude command line tool, through Commander
      router.ex             # who gets a session, and which one holds them
      session.ex            # one conversation, as a process
      supervisor.ex         # the router and the supervisor sessions run under
    tunnel.ex               # ChatAgent.Tunnel, the public URL facade
    tunnel/
      server.ex             # :gen_statem keeping a public URL open
      status.ex             # what the tunnel is doing, broadcast on change
      provider/
        adapter.ex          # behaviour every tunnel agent implements
        ngrok.ex            # ngrok agent, run and read over stdout
        pinggy.ex           # Pinggy SSH agent, run and read over stdout
    application.ex
  chat_agent_web/
    controllers/            # webhook endpoints, one controller per service
    live/                   # LiveView pages
    components/             # layouts and core components
assets/                     # asset sources, built by tailwind and esbuild
  css/app.css               # Tailwind and daisyUI, then this project's own CSS
  js/app.js                 # bundle entry point, starts the LiveSocket
  js/theme.js               # applied before first paint, so no theme flash
  js/hooks/                 # one file per LiveView hook, registered in js/app.js
  vendor/                   # Tailwind plugins for daisyUI and heroicons
priv/static/assets/         # build output, gitignored, never edited by hand
test/support/               # ConnCase and other test helpers
```

Module naming follows the app prefix: `ChatAgent.*` for domain code, `ChatAgentWeb.*` for anything web facing.

### Webhook routes

Webhook URLs follow one shape, `/<channel>/webhook`, with a router scope per channel.

| Route | Method | Purpose |
|---|---|---|
| `/whatsapp/webhook` | GET | WhatsApp subscription handshake (`hub.challenge`) |
| `/whatsapp/webhook` | POST | WhatsApp inbound messages |
| `/telegram/webhook` | POST | Telegram inbound updates, guarded by a secret header |
| `/channels` | GET | LiveView dashboard of every configured channel |
| `/health` | GET | Liveness probe, `{"status": "ok", "timestamp": ...}` |

There is one controller per channel, and one router scope per channel.
The channel is fixed by the route rather than read out of the body, which matters for more
than tidiness: each service authenticates differently, so letting the body pick the channel
would let the sender pick which authentication runs.
Only the verbs a provider actually uses are exposed: Telegram performs no handshake, so it
has no GET route.

Controllers stay thin.
Everything service specific lives in the channel module behind the behaviour, and the
controller only turns its results into responses.

Every channel reads its own configuration under its own module name, the same way a tunnel provider does:

```elixir
config :chat_agent, ChatAgent.Channel.Telegram,
  bot_token: nil,
  webhook_secret: nil,
  req_options: []
```

A key belongs to exactly one channel, so nothing has to be prefixed to stay apart, adding a channel adds no keys to a shared namespace, and each channel module documents the keys it reads.
Defaults live in `config/config.exs`, secrets are read from the environment in `config/runtime.exs`, and each key there is set only when its variable is present, so a local `config/<env>.override.exs` is never overwritten with a nil.

Runtime configuration comes from environment variables read in `config/runtime.exs`:
`ASSISTANT_SALTED_PASSWORD`, `TELEGRAM_ALLOWED_CHAT_IDS`, `WHATSAPP_ALLOWED_CHAT_IDS`, `ASSISTANT_WORKING_DIR_ROOT`, `ASSISTANT_WORKING_DIR`, `CLAUDE_EXECUTABLE`, `CLAUDE_ALLOWED_TOOLS`, `PINGGY_ACCESS_TOKEN`, `WHATSAPP_VERIFY_TOKEN`, `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `HEALTHCHECK_LOGGING`, `TUNNEL_PROVIDER`, `PUBLIC_URL`, `NGROK_AUTHTOKEN`, `NGROK_DOMAIN`.

### The public URL

A chat service delivers messages by calling a URL, so this app has to be reachable from the internet before any channel works.
`ChatAgent.Tunnel` answers that one question, `url/0`, whichever way the answer is arrived at.

| Where it runs | Where the URL comes from |
|---|---|
| Deployment behind DNS | `PUBLIC_URL`, or the endpoint's own `PHX_HOST` in production |
| Development machine | A tunnel agent, started when `TUNNEL_PROVIDER=ngrok` or `TUNNEL_PROVIDER=pinggy` is set |

Nothing else in the app knows which of the two it is running behind.
They are alternatives rather than layers: a configured URL is already public, so `ChatAgent.Tunnel.enabled?/0` is false whenever one is set and no agent is started, which is what keeps the URL the app reports and the URL its webhooks point at the same one.

```bash
# Open a public URL and point every channel's webhook at it
TUNNEL_PROVIDER=ngrok mix phx.server
```

Development runs the same code as anywhere else, and nothing is dev only: what differs is only which of the two configuration keys is filled in.
Out of the box neither is, so `mix phx.server` runs no agent and `ChatAgent.Tunnel.url/0` answers `{:error, :not_configured}`.
The provider can also be set for good in `config/dev.override.exs`, the gitignored local overrides file, instead of prefixing the variable each time.
`config/runtime.exs` sets each tunnel key only when its environment variable is present, precisely so it does not overwrite that file with a nil.

Running the agent opens a publicly reachable URL onto the local machine, and registering a webhook writes to the chat service's API, so both are opt in rather than the default.

`ChatAgent.Tunnel.Server` is a `:gen_statem` rather than a `GenServer` with a status field, because opening a tunnel is a sequence where each step can fail:

```
authenticating -> connecting -> registering -> connected
       ^-------------------------------------------|
              (agent exited, or a step failed)
```

Every failure returns to `:authenticating` after a backoff that grows with the number of consecutive attempts, and every state change is broadcast on the `"tunnel"` topic as a `ChatAgent.Tunnel.Status`.

Each transition is also logged once, as `tunnel_state_changed` with `from`, `to`, `attempt`, `retry_in_ms` and the URL, so a log read top to bottom is the path the machine took.
A retry reads as `from` and `to` being equal, and starting up reads as `from: :none`.
Every other line the agent writes is logged at `:debug` as `tunnel_agent_output`, which is what to turn on when the agent itself is the thing misbehaving.

The port it forwards to is not configured twice: with no `:port` set, the state machine asks the endpoint what it actually bound (`ChatAgentWeb.Endpoint.server_info/1`), which is the only answer that is right when the configuration says `port: 0`, and falls back to the configured port when nothing is listening.

The agent runs under `ChatAgent.Commander.run_link/2`, which is erlexec: the OS process is linked to the state machine, so the agent dying arrives as an `{:EXIT, _, _}` message and the state machine dying takes the agent with it.
That link is why nothing here has a `terminate/3` killing the agent by hand.
The URL is read out of the agent's stdout, buffered until a whole line is available, and handed to the provider's `parse/1`.

`:registering` is where each channel is told where its webhook now lives, through `c:ChatAgent.Channel.Adapter.register_webhook/1`.
A channel reads what its service currently has registered first and answers `{:ok, :unchanged}` when it already matches, so restarting the app is not a write to someone else's API.
A channel whose service takes no callback URL over its API answers `{:error, :not_supported}` and is not asked again, which is what WhatsApp does: the Cloud API sets it on the app itself rather than through the messaging credentials this app holds.

### Answering a conversation

`ChatAgent.Assistant` is the facade over anything that can answer a person, and `ChatAgent.Assistant.Router` decides who gets to ask.
A conversation starts closed:

```
/auth <password>                        open a session on the default assistant
/auth-<name> <password>                 name the assistant instead
/auth <password> --work-dir my-app-folder    say where it works
/stop                                   close the session
```

Quotes are only needed for a password with a space in it.

`--work-dir` names one directory **under `working_dir_root`**, which is the prefix a conversation types the tail of: with the root set to a workspace, `--work-dir my-app-folder` means that repository and nothing else.
Whoever knows the password picks this, so what is typed is resolved against the root and checked to have landed inside it: a name, a path climbing out with `..`, and an absolute path elsewhere are the same question, answered by where it ends up.
Without a root configured, no conversation chooses and the assistant works wherever it was configured to.
Set the root in `config/<env>.override.exs` per machine, or from `ASSISTANT_WORKING_DIR_ROOT`.

**Both live under `ChatAgent.Assistant`, and the default is written the way a conversation writes it:**

```elixir
config :chat_agent, ChatAgent.Assistant,
  working_dir_root: "/srv/checkouts",
  working_dir: "chat_agent"
```

One root governs both, so neither repeats the other and there is one place to change when the checkouts move.
An absolute `working_dir` is accepted only where no root is configured, which is the case of an assistant that works in exactly one place; a conversation never reaches that path, since `--work-dir` refuses without a root.
A default that does not resolve is logged as `assistant_working_dir_unusable` rather than silently ignored, and a root set on an assistant module instead is named at boot.

An open conversation is a `ChatAgent.Assistant.Session` process, started under a `DynamicSupervisor`, and everything about that conversation lives in it: the assistant it is talking to, the turns so far, and the idle timer.
That is why asking is allowed to block: it blocks the one conversation waiting for its own answer, and the router stays free to let the next person in.
The session ends by being asked to, by sitting idle, or by the router going down, and all three are the same ending: the conversation it held goes with it.

The router is what holds the protections, and each one exists for a reason worth keeping:

| Protection | Why |
|---|---|
| A wrong password is answered with silence | Saying "wrong password" confirms to whoever is guessing that a password is what opens this |
| No password configured means nobody is let in, and the router is not even started | A default password is a password everybody knows |
| Configuration holds a salted hash, never the password | Reading the configuration, the logs or a crash dump should give nobody a way in |
| A guess is checked with `Pbkdf2.verify_pass/2`, and `Pbkdf2.no_user_verify/0` runs when nothing is configured | A comparison that stops at the first wrong byte reports how much of a guess was right, and answering faster when there is no password to check says that too |
| A session closes after `session_timeout`, five minutes by default, and says so | A conversation somebody walked away from should not stay answerable, and one that ends in silence is indistinguishable from an assistant that broke |
| `/stop` closes one straight away | Waiting five minutes to end a conversation you have finished is not an answer |
| Only the last `history_limit` turns go into a prompt | A long conversation would otherwise grow a prompt without limit |
| Each conversation is its own process | One slow answer would otherwise stop every other conversation from being answered |
| Everything shown, stored or logged goes through `ChatAgent.Assistant.redact/1` | A password typed into a chat would otherwise be readable off the dashboard, out of the logs, and out of every prompt after it |
| The assistant holds its own deadline and stops what it started | erlexec's own timeout bounds starting a process, not running one, so a tool that hangs would be waited on for as long as it hangs |
| The run happens in a process of its own, not in the session's | A command's output arrives as messages, and reading them in the session would put another process's protocol in its mailbox |

A session says so when it opens and when it closes, on the `"assistant"` topic, which is how the dashboard shows which conversation is being answered and by what without asking anything.
Its identifier travels with every reply it sends, through `ChatAgent.Channel.send_message/4`'s `:sender` and `:identifiers` options: a reply written by an assistant says so, and only one typed at the dashboard says it came from there.

An assistant reports its failures as itself, and the session turns each into what the person waiting is told, and into whether there is any point carrying on.

| Reason | What the person is told | The session |
|---|---|---|
| `:timeout` | that it took too long, and to ask for less | stays open, since the next question may be smaller |
| `{:executable_not_found, name}` | that the tool is not installed here | closes, since that will not change while it is open |
| `{:command_failed, said}` | what the tool said, when that is about the service rather than about this machine | closes |
| anything else | an apology | closes |

Relaying what a tool said is deliberate: hitting a usage limit is the asker's to know, and an apology they can do nothing with is worse than the sentence the tool already wrote.
What is held back is anything carrying a filesystem path, since that describes this machine to somebody who cannot see it.
A word with a slash inside it, such as a time zone, is not a path.

### What the assistant is allowed to do

Permissions are the security question in this app, because the prompt comes from whoever authenticated with the bot, and what the tool does it does as whoever is running this.
Granting `"Bash(gh:*)"` grants it to every conversation that knows the password.

Nothing is granted by default: the list starts empty, and in this mode the tool refuses what it has no permission for rather than asking, since nobody is at a terminal to answer.

```elixir
config :chat_agent, ChatAgent.Assistant.Claude,
  working_dir: "/srv/checkouts/the-one-repository",
  allowed_tools: ["Read", "Grep", "Bash(git status)", "Bash(git diff:*)"],
  disallowed_tools: ["Bash(rm:*)"],
  permission_mode: "acceptEdits",
  add_dirs: [],
  model: nil,
  extra_args: []
```

`ASSISTANT_WORKING_DIR_ROOT`, `ASSISTANT_WORKING_DIR` and `CLAUDE_ALLOWED_TOOLS`, a comma separated list, set what matters most from the environment.
Grant the narrowest thing that does the job, and prefer a `working_dir` holding one repository over a broad `add_dirs`.

A policy longer than a list belongs in a settings file of its own, which says what is refused as well as what is allowed:

```elixir
config :chat_agent, ChatAgent.Assistant.Claude,
  settings: "/etc/chat_agent/claude-settings.json",
  permission_mode: "acceptEdits"
```

`priv/claude/settings.example.json` is a worked example for a bot that opens branches and pull requests.
Three things in it are worth copying whatever else changes:

- **Pushes are allowed only to a branch namespace**, `Bash(git push origin bot/*)`, so the bot cannot land on `main` even by asking nicely
- **Deny beats allow**, so the dangerous shapes are written out rather than left to the absence of an allow rule: force pushes, `git reset --hard`, `gh auth`, `gh secret`, reading `.env`
- **The credentials it borrows are the real limit.** It acts as whoever runs this app, so give that user a fine-grained token scoped to the one repository, and a checkout of nothing else

### What was measured, rather than assumed

The tool behaves differently when it is run with `-p`, which is how this app runs it, and the differences decide whether a policy has any effect at all.
Each row below was checked by running the real tool.

| Behaviour | Result |
|---|---|
| A policy passed with `--settings` (the `settings:` key) | applies |
| A repository's own `.claude/settings.json`, no flags | **ignored** |
| `~/.claude/settings.json`, no flags | ignored by the same mechanism, which is what `setting_sources: ["user"]` exists to change |
| A read-only command such as `git status` | runs with no rule at all |
| A write **inside** the working directory, under `permission_mode: "acceptEdits"` | allowed, with no `Write` rule |
| A write **outside** the working directory, same mode | **refused** unless `Write` or `Edit` is in the allow list |
| `permission_mode: "bypassPermissions"` | reaches outside the working directory with no rule at all |
| A `deny` rule under `bypassPermissions` | **still refused**, which makes the deny list the last guard if that mode is ever used |
| `cd <repo> && git checkout -b x`, with `Bash(cd:*)` **and** `Bash(git checkout:*)` allowed | **refused**: a compound command is not matched by rules covering each part |
| `git -C <repo> checkout -b x`, with `Bash(git -C:*)` | runs |

| `git -C <repo outside the working directory> …`, with `Bash(git -C:*)` and no `add_dirs` | runs |
| `WebFetch(domain:example.com)` fetching another domain | refused, so domain scoping holds |
| `WebFetch` with no pattern | fetches any domain |
| `WebFetch` allowed and one domain denied | refused for that domain, since deny beats allow |
| The same file written by a file tool | refused unless the directory is in `add_dirs` |

Those last two together are the shape of the boundary, and it is not the one the directory settings suggest.
**A shell command is not confined to the working directory at all**: `working_dir` and `add_dirs` scope the file tools, `Read`, `Edit` and `Write`, while a `Bash` rule is matched against the command string and can reach anything the user running this app can reach.
Granting `Bash(git -C:*)` grants every git repository on the machine, not the one the bot was pointed at.

The compound-command result decides how a bot working across several repositories should be told to work.
Running from a directory that holds many of them means reaching into one, and `cd repo && …` is refused however the parts are allowed, so either point `working_dir` at the single repository the bot works in, or grant `git -C` shaped rules and say so in the prompt.

The last two are the ones that surprise: a policy full of `Bash(...)` rules and no `Write` rule works perfectly until the tool reaches for a file outside the tree, and in `-p` there is no prompt to approve it, so it simply refuses.

Prefer the app's own settings file over `setting_sources`: the bot's policy is then reviewed where the bot is deployed, rather than by whoever last edited the repository it is working in, and it cannot pick up a personal allow list that was accumulated by clicking "yes" in an interactive session.

**A reply that could not be sent is logged.**
Only a message the channel accepted is broadcast, so a rejected reply reaches neither the person nor the dashboard: without `assistant_reply_not_sent` in the log, that looks exactly like a bug in here.

### Running OS commands

Everything that leaves the BEAM for the operating system goes through `ChatAgent.Commander`, which resolves its adapter from configuration on every call.
`ChatAgent.Commander.Local` is the only implementation and binds straight to erlexec, one line per call, so tests swap the whole thing for `ChatAgent.CommanderMock` and nothing reaches the machine.

A command is either a string, which a shell reads, or a list of an executable and its arguments, which no shell sees.
Anything carrying text from a stranger must use the list form: a prompt typed into a chat would otherwise have its punctuation read as syntax.
`ChatAgent.Assistant.Claude` uses the list form for exactly that reason, and the tunnel provider uses a string because the command line is its own.

**A command run for its output runs in a process of its own**, through `ChatAgent.Commander.Runner`.
Output arrives as messages, the run ends as another, and a deadline has to be held while both are outstanding: that is a protocol, and it belongs to a process that has nothing else to do.
Waiting for it inside a `GenServer` means the server answers nothing until the command is over, every other message queues behind it, and whatever the run says afterwards is left in a mailbox that is not its own.

    {:ok, output}                             # it finished, and this is everything it said
    {:error, {:exit_status, status, output}}  # it ran and failed
    {:error, :timeout}                        # it overran, and was stopped
    {:error, reason}                          # it never started, or ended some other way

The caller still waits, in a `GenServer.call/3`, because it asked for an answer.
What it no longer does is hold the run's messages.
Runs are started under `ChatAgent.Commander.RunnerSupervisor`, which the application starts, so a run belongs to the supervision tree rather than to whoever asked for it; the runner links to the command and monitors the caller, so neither outlives the other.

A run that is watched instead of read, such as the tunnel agent, is not this: it stays a `handle_info` in the state machine that owns it, since there is no single answer to wait for.

**Look for an executable before running it.**
`System.find_executable/1` first, and `{:error, {:executable_not_found, name}}` when it is not there.
Left to the run, a missing tool arrives as an exit status wrapped around a sentence from a shell, which reads like the tool refused rather than like it was never installed.

erlexec refuses to start when the BEAM runs as root.
A deployment that does (a container running as root, say) has to configure `config :erlexec, root: true, user: "...", limit_users: ["..."]` for the app to boot at all, which is one more reason a deployment behind DNS runs no tunnel.

### Who a channel will talk to

A webhook is reachable by whoever can find the bot, so a second list decides which conversations this app answers at all:

```elixir
config :chat_agent, ChatAgent.Channel.Telegram,
  allowed_chat_ids: ["123456", "-1001234567890"]
```

Empty means anyone, which is what a webhook does by default.
A list means those conversations and no others, **in both directions**: an inbound message from anywhere else is dropped in `ChatAgent.Channel.handle_message/2` before it is broadcast, so it reaches no dashboard and no assistant, and `send_message/4` refuses to send anywhere else with `{:error, {:conversation_not_allowed, id}}`.

The value is whatever identifies a conversation on that channel, a chat id for Telegram and a phone number for WhatsApp, compared as strings so a number in a payload and a string in a configuration file mean the same conversation.
A turned-away message is logged as `channel_message_ignored` with the conversation, which is how it gets added to the list when it should have been on it.

The webhook still answers normally to the service, since a stranger learns nothing from a reply that says it was handled.

### Request logging

`Plug.Telemetry` in the endpoint decides its level through `ChatAgentWeb.Logger.log/1`, so logging is a per-route decision rather than a global level.
`/health` logs nothing, because a probe running every few seconds would bury the requests worth reading, and `HEALTHCHECK_LOGGING=true` turns it back on when a probe is failing and you need to see it arrive.
Every other route logs at `:info`.
Route-specific logging rules belong in that module, not in a plug bolted onto a pipeline.

---

## Development Commands

```bash
# Install deps and compile (warnings as errors)
mix do deps.get + compile --warnings-as-errors

# Everything a fresh clone needs: deps, database, asset tool binaries, assets
mix setup

# Create, migrate and seed the database, or start it over
mix ecto.setup
mix ecto.reset

# Build assets once, without starting the server
mix assets.build

# Run locally
mix phx.server
iex -S mix phx.server

# Run all tests with coverage
mix test --cover

# Run a single test file
mix test test/chat_agent/channel_test.exs

# Format code, and the CI gate for it
mix format
mix format --check-formatted

# Credo lint (strict mode)
mix credo --strict

# Check unused dependencies
mix deps.unlock --check-unused

# Dialyzer type checking
mix dialyzer

# Security audit
mix deps.audit
mix sobelow --exit --threshold medium --skip -i Config.HTTPS

# Generate docs
mix docs

# Everything the pre-commit gate runs
mix precommit
```

The first `mix dialyzer` builds the PLT and takes a few minutes.
Later runs take seconds.
`priv/plts/` is gitignored, so cache that directory in CI.

Sobelow must run from the project root.
Do not pass `-r lib/chat_agent_web`, which is umbrella-app usage and makes Sobelow report "This does not appear to be a Phoenix application".

---

### Migrating a release

A release ships compiled code and no build tool, so `mix ecto.migrate` is not available where it matters most.
`ChatAgent.Release` is the same work, callable from the release's own binary:

```bash
bin/chat_agent eval "ChatAgent.Release.migrate()"
bin/chat_agent eval "ChatAgent.Release.rollback(ChatAgent.Repo, 20260819152520)"
```

Run it **before** starting the application rather than from inside it: a node that migrates on boot races every other node doing the same.

`migrate/0` makes the directory the database file lives in first, which `prepare_storage/0` also does on its own.
SQLite is a file, and opening one creates it, but only inside a directory that exists: a release pointed at a fresh volume through `DATABASE_PATH` has a path and no directory, and would otherwise fail on the migration rather than on the thing that is actually missing.

## Safety and Permissions

Rules for AI agents about which actions may run without asking and which require explicit confirmation first.

**Allowed without asking:**

- Reading and listing files anywhere in the repository
- Compiling the project (`mix compile`)
- Formatting or format-checking files (`mix format`)
- Linting (`mix credo`)
- Running the test suite, including `mix test --cover`
- Starting the local server to verify a change, as long as it is stopped afterwards

**Ask first:**

- Installing or updating packages (changing `mix.exs` deps, `mix deps.get` or `mix deps.update` after dependency changes)
- `git push`, opening a PR, or any other action that leaves the local machine
- Deleting files or changing permissions (`rm`, `chmod`)
- Sending real requests to the WhatsApp or Telegram APIs with production credentials, which includes registering a webhook
- Running a tunnel agent (`TUNNEL_PROVIDER=ngrok mix phx.server`, `TUNNEL_PROVIDER=pinggy mix phx.server`, or either agent directly), since it exposes the local machine publicly

---

## Testing

- **Framework:** ExUnit, with `test/support/` compiled only in the test environment
- **Behaviour mocks:** Mox. `ChatAgent.ChannelMock`, `ChatAgent.CommanderMock` and `ChatAgent.TunnelProviderMock` are defined in `test/test_helper.exs` against their behaviours, so a callback change breaks the tests at compile time
- **HTTP stubbing:** `Req.Test`, wired through each channel's own `:req_options` key in `config/test.exs`
- **Coverage threshold:** **90%**, enforced by `mix test --cover`. The suite currently sits at 100%
- **Excluded modules:** OTP and test scaffolding, plus modules whose functions are generated by `embed_templates` (see `ignore_modules` in `mix.exs`)

Use Mox to verify what reaches a channel, and `Req.Test` to stand in for the remote API.
Never mock the module under test: a channel module's own tests exercise the real implementation against a stubbed transport.

Mox also proves a **negative**, which is the point of several tests here.
With `setup :verify_on_exit!` and no expectation declared, any call to the mock fails the test.
That is how "a statuses-only webhook change reaches no channel" and "a request with an invalid secret reaches no channel" are asserted.

A test that overrides application configuration must be `async: false`, since that configuration is global.

A test whose subject runs the mock from another process needs `set_mox_global`, which is every test of something that runs a command: `ChatAgent.Commander.Runner` and `ChatAgent.Assistant.Claude` both answer from a runner process rather than from the test's.
Drive a runner with the messages erlexec would send it (`{:stdout, os_pid, chunk}`, `{:EXIT, exec_pid, reason}`), sent from inside the mocked `run_link/2` so they are in its mailbox before the test is told the command ran.

`ChatAgent.Tunnel.Server` does its work from its own process, so its test uses `set_mox_global`, and the mocked `run_link` returns a process it spawned with `spawn_link`, which leaves the fake agent linked to the state machine exactly as erlexec would.
Drive it with the messages it actually receives (`{:stdout, os_pid, chunk}`, killing the linked process) and wait on the mock calls rather than on a broadcast, since a broadcast can be sent before the call the test is verifying.

### Verify UI work in a browser

Server-side tests can pass while the page is dead in a real browser.
When changing anything the browser touches (LiveView, layouts, CSS, assets, CSP), load the page in a real browser and check the console is clean before calling it done.
Check light theme, dark theme, and a narrow viewport.

---

## Code Patterns

### Channel Adapter Pattern

Each chat service is one module implementing `ChatAgent.Channel.Adapter`, covering both directions:

```elixir
@callback handle_message(payload :: map()) ::
            :ok | {:ok, ChatAgent.Channel.Message.t()} | {:error, term()}
@callback send_message(recipient :: recipient(), body :: String.t()) :: :ok | {:error, term()}
```

`ChatAgent.Channel` is a thin facade that routes by channel name, resolving the module from configuration on every call:

```elixir
ChatAgent.Channel.handle_message(:telegram, update)
ChatAgent.Channel.send_message(:telegram, chat_id, "Hello")
```

An unknown channel returns `{:error, {:unknown_channel, channel}}` rather than raising.

**Adding a channel is three steps:** write the module, register it in `config/config.exs`, then give it a controller and a router scope for its webhook.

```elixir
config :chat_agent, ChatAgent.Channel,
  adapters: [
    whatsapp: ChatAgent.Channel.Whatsapp,
    telegram: ChatAgent.Channel.Telegram
  ]
```

```elixir
scope "/my_channel/webhook", ChatAgentWeb do
  pipe_through :api

  post "/", MyChannelController, :receive
end
```

Nothing else needs editing.
The LiveView renders whatever `ChatAgent.Channel.list/0` returns, in the order configuration lists them.

The behaviour also carries what each service needs at its webhook: `authenticate/1` proves the
request came from the provider, `inbound_messages/1` unwraps whatever envelope it uses, and
`verify_subscription/1` answers a handshake or reports `{:error, :not_found}` when the provider
performs none.
Keeping all three with the channel is what lets a controller be a handful of lines that map
results to status codes.

### PubSub

Every inbound chat message is broadcast on `Phoenix.PubSub` under `ChatAgent.PubSub`.
The topic is `"channel:<name>"` and the message is `{:message, %ChatAgent.Channel.Message{}}`.
Broadcast from the facade, subscribe from LiveView.

### LiveView

Real-time pages live in `lib/chat_agent_web/live/`.
Subscribe inside `if connected?(socket)` so the static render does no subscribing.

### Client hooks

One file per hook in `assets/js/hooks/`, named after the hook it exports, imported into `js/app.js` and registered in the `Hooks` map passed to `LiveSocket`.

A hook that dismisses something should tell the server rather than only change the DOM.
`AutoDismissFlash` pushes `lv:clear-flash`, which LiveView handles natively, so the flash leaves the socket and LiveView removes the element.
Hiding the node instead leaves the flash set on the server, and the next identical message produces no diff and is never seen.

Durations that the visitor can see belong in CSS, where `prefers-reduced-motion` can reach them.
`AutoDismissFlash` reads the fade length back out of the computed style rather than repeating it in JavaScript.

---

## Code Preferences

Prescriptive rules for writing new code in this project.

- **An adapter owns its whole implementation.**
  The module implementing a behaviour holds its API calls, config reads, and response handling.
  Do not add a separate client module that the adapter only delegates to: an adapter whose body is `defdelegate` is an empty layer.
- **Each service decides what success means for itself.**
  One API signals failure with an HTTP status, another answers 200 with a failure flag in the body.
  That judgement belongs in the channel module, never in a shared HTTP wrapper.
- **Return values, do not raise, for expected failures.**
  Use `Req.post/2` rather than `Req.post!/2` so a network failure returns `{:error, reason}` instead of raising inside a webhook request.
- **Inbound handlers accept any payload the service can send.**
  Webhooks deliver more than chat messages (delivery receipts, edits, reactions).
  A `FunctionClauseError` there becomes a failed webhook response and a retry from the other side, so always keep a catch-all clause.
- **Configuration is read at call time**, via `Application.get_env/3`, so a config change takes effect without a recompile and tests can swap an implementation.
- **Keep specs exact.**
  Dialyzer runs with `:underspecs`, so a spec wider than the success typing fails the build.

---

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - A `live_session :current_user` scope - for routes that need the current user but don't require authentication, similar to `:fetch_current_scope_for_user`
  - A `live_session :require_authenticated_user` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_user` can only be defined __once__ in the router, so all routes for the `live_session :current_user`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_user` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{ChatAgentWeb.UserAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/users/settings", UserLive.Settings, :edit
        live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
        # our own routes that require logged in user
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_user` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_user,
        on_mount: [{ChatAgentWeb.UserAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- usage-rules-end -->
---

## Commit Message Style

Use `feat(scope): short description`, matching the PR title (also `fix`, `refactor`, `docs`, `test`, `chore`).

- Keep the subject line under about 72 characters
- The body explains what changed and why, and carries the risk assessment so it survives outside GitHub
- Never add an AI agent as a commit co-author

---

## Pull Requests

### Branch naming

Branches are named `{github-user}/feature-or-bugfix-name`, for example `thiagoesteves/fix-webhook-secret-check`.
Not `fix/...` or `feature/...`.

### PR checklist

Before opening a PR, confirm every item:

- [ ] Title follows `feat(scope): short description` (also `fix`, `refactor`, `docs`, `test`, `chore`)
- [ ] All checks green locally before committing, which `mix precommit` covers, plus `mix dialyzer` when specs or types changed
- [ ] Diff is small and focused on one change; unrelated cleanups go in their own PR
- [ ] Description briefly summarises what changed and why
- [ ] Debug output (`IO.inspect`, `dbg`) and leftover comments removed
- [ ] UI changes verified in a real browser, in light and dark themes and at a narrow viewport
- [ ] Risk assessment included (see below)

### Risk assessment

Every PR description must include a **Risk assessment** section with:

- **Impact:** what changes for users or operators when this ships
- **Blast radius:** which modules are touched and which are guaranteed untouched
- **Regression risk:** low, medium or high, with the reasoning
- **Rollback:** how to revert, including any config or deploy-order steps

Call out deploy ordering explicitly when new configuration has to ship with the code.
For bug fixes, state how the bug was reproduced, ideally with a test that fails without the fix.

When a PR is authored by an AI agent, credit it at the end of the description with:
`🤖 Generated with [Devin](https://devin.ai) (<model name>)` when running through Devin,
or `🤖 Generated with [Claude Code](https://claude.com/claude-code) (<model name>)` when running through Claude Code directly.
`<model name>` is the model the agent is running on (e.g. `GLM-5.2 High`, `Claude Sonnet 4.5`).
Never add the agent as commit co-author.

---

## CI/CD (GitHub Actions)

All PRs target `main` and must pass `.github/workflows/pr-ci.yaml`, which runs three jobs.

| Job | Command |
|---|---|
| Setup | `mix do deps.get + compile --warnings-as-errors` |
| Test | `mix test --cover --warnings-as-errors` |
| Static Analysis | `mix deps.unlock --check-unused` |
| Static Analysis | `mix credo --strict` |
| Static Analysis | `mix docs --failed` |
| Static Analysis | `mix deps.audit` |
| Static Analysis | `mix sobelow --exit --threshold medium --skip -i Config.HTTPS` |
| Static Analysis | `mix format --check-formatted` |
| Static Analysis | `mix dialyzer --format github` |

The BEAM version comes from `.tool-versions` with `version-type: strict`, so changing that file changes CI.
The PLT is cached separately from `_build` and `deps`.

---

## Code Quality Rules

- **Max line length:** 120 characters, enforced by Credo
- Credo runs in `--strict` mode; fix every warning before merging
- Dialyzer PLT lives at `priv/plts/project.plt`, with `:error_handling`, `:underspecs` and `:unknown` enabled
- All compiler warnings are treated as errors in CI
- Every public function carries a `@spec`, and every module a `@moduledoc`

---

## Frontend Assets

Sources live in `assets/`, and `priv/static/assets/` holds only build output, which is gitignored.
Edit `assets/`, never the built files.

- `assets/css/app.css` is the single stylesheet: Tailwind v4 and daisyUI at the top, then this project's own hand written rules, which win where the two overlap. Tailwind v4 needs no `tailwind.config.js`; keep the `@import "tailwindcss" source(none)` and `@source` lines, since the `@source` paths are what make it scan the HEEx for classes in use
- `assets/js/app.js` is the bundle entry point. Dependencies resolve from `deps/` through `NODE_PATH`, so import `phoenix` and `phoenix_live_view` as packages rather than checking a copy in
- `assets/js/theme.js` is a second entry point, loaded synchronously ahead of the stylesheet so the saved theme is applied before first paint. Do not defer it
- `assets/js/hooks/` holds one file per LiveView hook
- `assets/vendor/` holds the Tailwind plugins for daisyUI and heroicons. Update them from their releases rather than editing them, and note the icons themselves come from the `heroicons` dependency in `mix.exs`

`tailwind` and `esbuild` install their own platform binaries, so there is no Node toolchain to manage and no `package.json` unless a dependency is installed with npm.

| Task | Command |
|---|---|
| Install the tool binaries | `mix assets.setup` |
| Build once | `mix assets.build` |
| Build for a release | `mix assets.deploy` (minifies, then digests) |
| Rebuild while developing | nothing, `mix phx.server` watches both |

The test suite does not read the built files, so CI needs no asset step.
A release does: `mix assets.deploy` before `mix release`.

---

## Key Dependencies

Exact versions are in `mix.lock`; do not trust version numbers written in docs.

| Library | Purpose |
|---|---|
| phoenix / phoenix_live_view | Web framework and real-time UI |
| bandit | HTTP server |
| req | HTTP client for the messaging APIs |
| jason | JSON encoding and decoding |
| dns_cluster | Node discovery |
| mox | Behaviour based mocking in tests |
| credo / dialyxir / sobelow / mix_audit | Static analysis and security, build time only |
| ex_doc | Documentation generation |
