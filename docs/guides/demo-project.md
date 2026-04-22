# Demo project walkthrough

Step-by-step to stand up a fresh Phoenix + Ash app that exercises
`ash_feedback` end-to-end — submit a feedback via the widget, see it
persisted, and transition it through the triage state machine.

**What you'll have when done**: an `ash_feedback_demo` Phoenix app with
a floating bug-report widget (rrweb session recording), feedback
rows stored as an Ash resource with PaperTrail versioning, and the
full triage workflow accessible via IEx and a minimal admin
LiveView.

> **Note**: The drop-in admin LiveView
> (`AshFeedback.UI.AdminLive`) is [Phase 5g](../plans/5g-admin-live.md)
> — not yet shipped. This guide includes a minimal inline LV
> scaffold (~80 lines) as a placeholder. When 5g lands, replace the
> inline scaffold with a single `live "/admin/feedback",
> AshFeedback.UI.AdminLive` call.

## Prerequisites

- Elixir 1.14+
- Postgres running locally (Docker or native)
- Git

## 1. Bootstrap a fresh Phoenix + Ash app

Install the archives once:

```bash
mix archive.install hex igniter_new --force
mix archive.install hex phx_new 1.8.5 --force
```

Scaffold the app with every Ash extension wired up in a single
command — `igniter` patches mix.exs, config, router, endpoint, and
runs the installers for each package:

```bash
mix igniter.new ash_feedback_demo --with phx.new \
  --install ash,ash_phoenix \
  --install ash_postgres,ash_authentication \
  --install ash_authentication_phoenix,ash_admin \
  --install ash_state_machine,ash_paper_trail \
  --auth-strategy magic_link \
  --setup --yes

cd ash_feedback_demo
```

What that gives you:

| Flag | Effect |
|------|--------|
| `--with phx.new` | Runs `phx.new` under the hood (Postgres, binary-id, etc. sane defaults) |
| `--install ash,ash_phoenix,ash_postgres` | Ash 3.x + Phoenix glue + Postgres data layer |
| `--install ash_authentication,ash_authentication_phoenix` | Auth + the LiveView sign-in pages |
| `--install ash_admin` | Bonus: `/admin` dashboard for poking at resources while you develop |
| `--install ash_state_machine,ash_paper_trail` | Required by `ash_feedback` |
| `--auth-strategy magic_link` | Magic-link auth (no password setup friction for the demo) |
| `--setup --yes` | Creates the DB, runs initial migrations, accepts all prompts |

Verify the server comes up:

```bash
mix phx.server
# → visit http://localhost:4000, use /sign-in to send yourself a magic link
```

Once you can sign in, stop the server and move on.

## 2. Add the feedback libraries

Edit `mix.exs` — add these two entries to `deps/0`:

```elixir
{:ash_feedback, github: "jhlee111/ash_feedback", branch: "main"}
```

That's it. `phoenix_replay` comes transitively from `ash_feedback`'s
deps (also at `branch: "main"`), so you don't need to list it
yourself for the demo.

```bash
mix deps.get
```

### Pinning specific SHAs (recommended for production)

For reproducibility, pin each library to an explicit SHA. When you
pin `phoenix_replay` directly, you MUST add `override: true` —
otherwise Mix treats your `ref:` pin as diverging from the
transitive `branch: "main"` in `ash_feedback`'s own `mix.exs` and
refuses to resolve:

```elixir
{:phoenix_replay,
 github: "jhlee111/phoenix_replay", ref: "ea18972", override: true},
{:ash_feedback, github: "jhlee111/ash_feedback", ref: "fab3df8"}
```

### Using local path deps (library development)

If you're hacking on `ash_feedback` or `phoenix_replay` locally and
want the demo app to use your sibling checkouts, switch both to
`path:` entries AND keep `override: true` on `phoenix_replay` (the
library's own mix.exs still ships a `github:` spec for it):

```elixir
{:phoenix_replay, path: "../phoenix_replay", override: true},
{:ash_feedback, path: "../ash_feedback"}
```

## 3. Install phoenix_replay

Follow [phoenix_replay's README](https://github.com/jhlee111/phoenix_replay#installation)
steps 1–5. The short version:

```bash
mix phoenix_replay.install
mix ecto.migrate
```

Edit `config/config.exs`:

```elixir
config :phoenix_replay,
  environment: config_env(),
  identify: {AshFeedbackDemo.Feedback.Identify, :fetch_identity, []},
  metadata: {AshFeedbackDemo.Feedback.Identify, :fetch_metadata, []},
  # Temporary — ash_feedback flips this in step 4.
  storage: {PhoenixReplay.Storage.Ecto, repo: AshFeedbackDemo.Repo},
  session_token_secret: "dev-secret-at-least-32-bytes-long-xxxxxx",
  limits: [max_batch_bytes: 5_000_000]
```

Add pipelines + routes in `lib/ash_feedback_demo_web/router.ex`:

```elixir
import PhoenixReplay.Router

pipeline :feedback_ingest do
  plug :accepts, ["json"]
  plug :fetch_session
  plug :protect_from_forgery
  plug :load_from_session
end

pipeline :admin_json do
  plug :accepts, ["json"]
  plug :fetch_session
  plug :load_from_session
end

scope "/" do
  pipe_through :feedback_ingest
  feedback_routes "/api/feedback"
end

scope "/admin" do
  pipe_through :admin_json
  admin_routes "/feedback"
end
```

Widget asset plug in `lib/ash_feedback_demo_web/endpoint.ex`:

```elixir
plug Plug.Static,
  at: "/phoenix_replay",
  from: {:phoenix_replay, "priv/static/assets"},
  gzip: false
```

Widget mount in `lib/ash_feedback_demo_web/components/layouts/root.html.heex`
(right before `</body>`):

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
/>
```

Identity callback — create `lib/ash_feedback_demo/feedback/identify.ex`:

```elixir
defmodule AshFeedbackDemo.Feedback.Identify do
  def fetch_identity(conn) do
    case conn.assigns[:current_user] do
      %{id: id} = user ->
        %{kind: :user, id: to_string(id),
          attrs: %{"email" => to_string(user.email)}}
      _ -> nil
    end
  end

  def fetch_metadata(conn) do
    %{
      "environment" => to_string(Application.get_env(:phoenix_replay, :environment)),
      "user_agent" => case Plug.Conn.get_req_header(conn, "user-agent"), do: ([v | _] -> v; _ -> nil),
      "remote_ip" => conn.remote_ip |> :inet.ntoa() |> to_string()
    }
  end
end
```

## 4. Install ash_feedback

Create `lib/ash_feedback_demo/feedback.ex`:

```elixir
defmodule AshFeedbackDemo.Feedback do
  use Ash.Domain, otp_app: :ash_feedback_demo

  resources do
    resource AshFeedbackDemo.Feedback.Entry
    resource AshFeedbackDemo.Feedback.Entry.Version
    resource AshFeedbackDemo.Feedback.Comment
  end
end
```

Create `lib/ash_feedback_demo/feedback/entry.ex`:

```elixir
defmodule AshFeedbackDemo.Feedback.Entry do
  use AshFeedback.Resources.Feedback,
    domain: AshFeedbackDemo.Feedback,
    repo: AshFeedbackDemo.Repo,
    assignee_resource: AshFeedbackDemo.Accounts.User,
    pubsub: AshFeedbackDemo.PubSub,
    paper_trail_actor: {AshFeedbackDemo.Accounts.User,
                       [domain: AshFeedbackDemo.Accounts]}
end
```

Create `lib/ash_feedback_demo/feedback/comment.ex` (optional — skip if
you don't want comments):

```elixir
defmodule AshFeedbackDemo.Feedback.Comment do
  use AshFeedback.Resources.FeedbackComment,
    domain: AshFeedbackDemo.Feedback,
    repo: AshFeedbackDemo.Repo,
    feedback_resource: AshFeedbackDemo.Feedback.Entry,
    author_resource: AshFeedbackDemo.Accounts.User,
    pubsub: AshFeedbackDemo.PubSub
end
```

Register the domain in `config/config.exs`:

```elixir
config :ash_feedback_demo,
  ash_domains: [AshFeedbackDemo.Accounts, AshFeedbackDemo.Feedback]
```

Flip the `:phoenix_replay :storage` config to the Ash adapter:

```elixir
config :phoenix_replay,
  # ... other keys unchanged ...
  storage: {AshFeedback.Storage,
            resource: AshFeedbackDemo.Feedback.Entry,
            repo: AshFeedbackDemo.Repo}
```

Generate migrations for the PaperTrail `_versions` table:

```bash
mix ash.codegen add_feedback_resources
mix ash.migrate
```

## 5. Sign in with magic link

Because the app was scaffolded with `--auth-strategy magic_link`,
there's no password flow — you request a link by email, then click it.

```bash
iex -S mix phx.server
```

1. Visit `http://localhost:4000/sign-in`.
2. Enter `qa@example.com`.
3. In dev, the magic link is printed to the IEx console (no real
   mail server needed) — copy-paste it into the browser.
4. You're now signed in as `qa@example.com` — AshAuthentication
   registers the user on first sign-in, so no explicit seed step.

Verify in IEx:

```elixir
iex> AshFeedbackDemo.Accounts.User |> Ash.read!(authorize?: false)
[%AshFeedbackDemo.Accounts.User{email: "qa@example.com", ...}]
```

The magic-link console printer only runs in dev. In prod, configure
a real mail sender via `config :ash_feedback_demo, :mailer`.

## 6. Submit a feedback

1. Open `http://localhost:4000/` while signed in.
2. Click the floating bug icon (bottom-right).
3. Fill in description + severity, click **Submit**.
4. The widget reports success.

Verify in IEx:

```elixir
iex> AshFeedbackDemo.Feedback.Entry.list_feedback!()
[%AshFeedbackDemo.Feedback.Entry{
   id: "fbk_...",
   description: "...",
   severity: :medium,
   status: :new,
   reported_on_env: :dev,
   ...
 }]
```

## 7. Triage via IEx

```elixir
iex> [fb | _] = AshFeedbackDemo.Feedback.Entry.list_feedback!()

# Acknowledge
iex> AshFeedbackDemo.Feedback.Entry.acknowledge!(fb.id, actor: user)

# Assign
iex> AshFeedbackDemo.Feedback.Entry.assign!(fb.id, %{assignee_id: user.id}, actor: user)

# Verify (requires PR URL)
iex> AshFeedbackDemo.Feedback.Entry.verify!(
...>   fb.id,
...>   %{pr_urls: ["https://github.com/you/repo/pull/1"]},
...>   actor: user
...> )

# Resolve
iex> AshFeedbackDemo.Feedback.Entry.resolve!(fb.id, %{}, actor: user)
```

Each transition publishes to PubSub (`feedback:status_changed`,
`feedback:verified`, `feedback:resolved`) and records a Version row
with the actor.

## 8. Browse via AshAdmin (free UI) or drop in a minimal LV

`--install ash_admin` (step 1) gave you `/admin` out of the box —
visit `http://localhost:4000/admin` and you'll see every Ash resource
in the app, including `Feedback.Entry`. Good enough for inspecting
rows, less good for a triage workflow.

For a more opinionated triage-style LV until
[`AshFeedback.UI.AdminLive`](../plans/5g-admin-live.md) (Phase 5g)
ships, drop this ~80-line LV into your app as a starting point. It
lists feedbacks in a plain table + shows the action buttons inline.

`lib/ash_feedback_demo_web/live/admin/feedback_live.ex`:

```elixir
defmodule AshFeedbackDemoWeb.Admin.FeedbackLive do
  use AshFeedbackDemoWeb, :live_view

  alias AshFeedbackDemo.Feedback.Entry

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshFeedbackDemo.PubSub, "feedback:status_changed")
      Phoenix.PubSub.subscribe(AshFeedbackDemo.PubSub, "feedback:created")
    end

    {:ok, assign(socket, feedbacks: load())}
  end

  def handle_info({:feedback_status_changed, _}, socket),
    do: {:noreply, assign(socket, feedbacks: load())}

  def handle_info({:feedback_created, _}, socket),
    do: {:noreply, assign(socket, feedbacks: load())}

  def handle_event("acknowledge", %{"id" => id}, socket) do
    Entry.acknowledge!(id, actor: socket.assigns.current_user)
    {:noreply, assign(socket, feedbacks: load())}
  end

  defp load do
    Entry.list_feedback!()
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl">Feedback triage</h1>
    <table class="w-full">
      <thead>
        <tr><th>Status</th><th>Severity</th><th>Env</th><th>Description</th><th/></tr>
      </thead>
      <tbody>
        <tr :for={f <- @feedbacks}>
          <td>{f.status}</td>
          <td>{f.severity}</td>
          <td>{f.reported_on_env}</td>
          <td>{f.description}</td>
          <td>
            <button
              :if={f.status == :new}
              phx-click="acknowledge"
              phx-value-id={f.id}
              class="px-2 py-1 bg-blue-500 text-white rounded"
            >
              Acknowledge
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
```

Route it in the router (put it inside your admin auth scope):

```elixir
live "/admin/feedback", AshFeedbackDemoWeb.Admin.FeedbackLive
```

This is intentionally crude — extend with severity filters, a detail
panel, verify/dismiss modals, the comment thread, etc. as your
project needs. Phase 5g will ship a full drop-in that replaces all
of the above.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Widget renders but submit returns 401 | `fetch_identity/1` is returning `nil` — sign in first, or adjust the identity callback to accept anonymous users. |
| `cache lookup failed for type` after migration | Restart the server. Postgrex's type cache is stale after schema changes. |
| Widget assets 404 | Verify `Plug.Static` mount in endpoint.ex points at `{:phoenix_replay, "priv/static/assets"}`. |
| `belongs_to :assignee` not loading | If your User uses AshPrefixedId, pass `assignee_attribute_type: User.ObjectId` to the macro. See README gotchas. |
| PaperTrail Version rows have `user_id: nil` | Ensure `paper_trail_actor:` opt is set on the concrete resource AND `mix ash.migrate` has run (adds the `user_id` FK column). |

## Next steps

- Hook up the deploy-pipeline endpoints (`list_preview_blockers`,
  `list_verified_non_preview`, `promote_verified_to_resolved`) —
  see [`../../README.md#deploy-pipeline-integration`](../../README.md#deploy-pipeline-integration).
- Layer AshGrant policies on the concrete resources for scope-based
  access control.
- Watch for Phase 5g (Admin UI drop-in) — replaces the inline LV
  scaffold.
