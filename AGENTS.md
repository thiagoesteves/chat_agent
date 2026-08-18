# ChatAgent - Agent Code Guide

## Project Overview

ChatAgent is a Phoenix application that receives chat messages from external messaging services over webhooks and sends replies back to them.
It currently speaks WhatsApp (Cloud API) and Telegram (Bot API).
There is no database: inbound messages are handled in process and broadcast over PubSub, and a LiveView dashboard shows them arriving.

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
    application.ex
  chat_agent_web/
    controllers/            # webhook endpoints, one controller per service
    live/                   # LiveView pages
    components/             # layouts and core components
priv/static/assets/         # hand-maintained, there is no asset build step
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

There is one controller per channel, and one router scope per channel.
The channel is fixed by the route rather than read out of the body, which matters for more
than tidiness: each service authenticates differently, so letting the body pick the channel
would let the sender pick which authentication runs.
Only the verbs a provider actually uses are exposed: Telegram performs no handshake, so it
has no GET route.

Controllers stay thin.
Everything service specific lives in the channel module behind the behaviour, and the
controller only turns its results into responses.

Runtime configuration comes from environment variables read in `config/runtime.exs`:
`WHATSAPP_VERIFY_TOKEN`, `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`.

---

## Development Commands

```bash
# Install deps and compile (warnings as errors)
mix do deps.get + compile --warnings-as-errors

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
- Sending real requests to the WhatsApp or Telegram APIs with production credentials

---

## Testing

- **Framework:** ExUnit, with `test/support/` compiled only in the test environment
- **Behaviour mocks:** Mox. `ChatAgent.ChannelMock` is defined in `test/test_helper.exs` against `ChatAgent.Channel.Adapter`, so a callback change breaks the tests at compile time
- **HTTP stubbing:** `Req.Test`, wired through the `:whatsapp_req_options` and `:telegram_req_options` config keys in `config/test.exs`
- **Coverage threshold:** **90%**, enforced by `mix test --cover`. The suite currently sits at 100%
- **Excluded modules:** OTP and test scaffolding, plus modules whose functions are generated by `embed_templates` (see `ignore_modules` in `mix.exs`)

Use Mox to verify what reaches a channel, and `Req.Test` to stand in for the remote API.
Never mock the module under test: a channel module's own tests exercise the real implementation against a stubbed transport.

Mox also proves a **negative**, which is the point of several tests here.
With `setup :verify_on_exit!` and no expectation declared, any call to the mock fails the test.
That is how "a statuses-only webhook change reaches no channel" and "a request with an invalid secret reaches no channel" are asserted.

A test that overrides application configuration must be `async: false`, since that configuration is global.

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

This project was generated with `--no-assets`, so **there is no bundler and no asset build step**.
Everything under `priv/static/assets/` is hand-maintained and served as written.

- `js/app.js` is an ES module loaded with `<script type="module">`. It starts the LiveSocket
- `js/vendor/` holds the Phoenix and LiveView ES module builds, copied from `deps/`. Refresh them with the commands in the header of `app.js` after upgrading either dependency
- `css/app.css` holds the application styles and is loaded **after** `default.css` so it wins where the two overlap
- `default.css` is a curated subset shipped by the generator. It contains only the utility classes the generated files use, so an arbitrary utility class will silently do nothing. Check it is present before relying on it, or write the CSS by hand

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
