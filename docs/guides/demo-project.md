# Demo project walkthrough

Step-by-step to stand up a fresh Phoenix + Ash app that exercises
`ash_feedback` end-to-end — submit a feedback via the widget, see it
persisted, and transition it through the triage state machine.

**What you'll have when done**: a `feedback_demo` Phoenix app with
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
mix igniter.new feedback_demo --with phx.new \
  --install ash,ash_phoenix \
  --install ash_postgres,ash_authentication \
  --install ash_authentication_phoenix,ash_admin \
  --install ash_state_machine,ash_paper_trail \
  --auth-strategy magic_link \
  --setup --yes

cd feedback_demo
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
  identify: {FeedbackDemo.Feedback.Identify, :fetch_identity, []},
  metadata: {FeedbackDemo.Feedback.Identify, :fetch_metadata, []},
  # Temporary — ash_feedback flips this in step 4.
  storage: {PhoenixReplay.Storage.Ecto, repo: FeedbackDemo.Repo},
  session_token_secret: "dev-secret-at-least-32-bytes-long-xxxxxx",
  limits: [max_batch_bytes: 5_000_000]
```

Add pipelines + routes in `lib/feedback_demo_web/router.ex`:

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

Widget asset plug in `lib/feedback_demo_web/endpoint.ex`:

```elixir
plug Plug.Static,
  at: "/phoenix_replay",
  from: {:phoenix_replay, "priv/static/assets"},
  gzip: false
```

Widget mount in `lib/feedback_demo_web/components/layouts/root.html.heex`
(right before `</body>`):

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
/>
```

Identity callback — create `lib/feedback_demo/feedback/identify.ex`:

```elixir
defmodule FeedbackDemo.Feedback.Identify do
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

Create `lib/feedback_demo/feedback.ex`:

```elixir
defmodule FeedbackDemo.Feedback do
  use Ash.Domain, otp_app: :feedback_demo

  resources do
    resource FeedbackDemo.Feedback.Entry
    resource FeedbackDemo.Feedback.Entry.Version
    resource FeedbackDemo.Feedback.Comment
  end
end
```

Create `lib/feedback_demo/feedback/entry.ex`:

```elixir
defmodule FeedbackDemo.Feedback.Entry do
  use AshFeedback.Resources.Feedback,
    domain: FeedbackDemo.Feedback,
    repo: FeedbackDemo.Repo,
    assignee_resource: FeedbackDemo.Accounts.User,
    pubsub: FeedbackDemo.PubSub,
    paper_trail_actor: {FeedbackDemo.Accounts.User,
                       [domain: FeedbackDemo.Accounts]}
end
```

Create `lib/feedback_demo/feedback/comment.ex` (optional — skip if
you don't want comments):

```elixir
defmodule FeedbackDemo.Feedback.Comment do
  use AshFeedback.Resources.FeedbackComment,
    domain: FeedbackDemo.Feedback,
    repo: FeedbackDemo.Repo,
    feedback_resource: FeedbackDemo.Feedback.Entry,
    author_resource: FeedbackDemo.Accounts.User,
    pubsub: FeedbackDemo.PubSub
end
```

Register the domain in `config/config.exs`:

```elixir
config :feedback_demo,
  ash_domains: [FeedbackDemo.Accounts, FeedbackDemo.Feedback]
```

Flip the `:phoenix_replay :storage` config to the Ash adapter:

```elixir
config :phoenix_replay,
  # ... other keys unchanged ...
  storage: {AshFeedback.Storage,
            resource: FeedbackDemo.Feedback.Entry,
            repo: FeedbackDemo.Repo}
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
iex> FeedbackDemo.Accounts.User |> Ash.read!(authorize?: false)
[%FeedbackDemo.Accounts.User{email: "qa@example.com", ...}]
```

The magic-link console printer only runs in dev. In prod, configure
a real mail sender via `config :feedback_demo, :mailer`.

## 6. Submit a feedback

1. Open `http://localhost:4000/` while signed in.
2. Click the floating bug icon (bottom-right).
3. Fill in description + severity, click **Submit**.
4. The widget reports success.

Verify in IEx:

```elixir
iex> FeedbackDemo.Feedback.Entry.list_feedback!()
[%FeedbackDemo.Feedback.Entry{
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
iex> [fb | _] = FeedbackDemo.Feedback.Entry.list_feedback!()

# Acknowledge
iex> FeedbackDemo.Feedback.Entry.acknowledge!(fb.id, actor: user)

# Assign
iex> FeedbackDemo.Feedback.Entry.assign!(fb.id, %{assignee_id: user.id}, actor: user)

# Verify (requires PR URL)
iex> FeedbackDemo.Feedback.Entry.verify!(
...>   fb.id,
...>   %{pr_urls: ["https://github.com/you/repo/pull/1"]},
...>   actor: user
...> )

# Resolve
iex> FeedbackDemo.Feedback.Entry.resolve!(fb.id, %{}, actor: user)
```

Each transition publishes to PubSub (`feedback:status_changed`,
`feedback:verified`, `feedback:resolved`) and records a Version row
with the actor.

## 8. Browse via AshAdmin (free UI) or drop in a minimal LV

`--install ash_admin` (step 1) gave you `/admin` out of the box —
visit `http://localhost:4000/admin` and you'll see every Ash resource
in the app, including `Feedback.Entry`. Good enough for inspecting
rows, less good for a triage workflow, and it can't replay the
session.

For a more opinionated triage LV with **rrweb replay playback** until
[`AshFeedback.UI.AdminLive`](../plans/5g-admin-live.md) (Phase 5g)
ships, drop this ~110-line LV into your app. It lists feedbacks,
opens a detail panel on row click, and embeds the `rrweb-player` via
`phoenix_replay`'s standalone components.

> **Expose `AshFeedback.Domain` to AshAdmin first.** The library's
> `Ash.Domain` macro doesn't wire up `AshAdmin.Domain` — add
> `extensions: [AshAdmin.Domain]` and an `admin do show? true end`
> block to `FeedbackDemo.Feedback` (step 4) if you want
> `Feedback.Entry` / `.Version` / `.Comment` to appear in the
> `/admin` sidebar.

`lib/feedback_demo_web/live/admin/feedback_live.ex`:

```elixir
defmodule FeedbackDemoWeb.Admin.FeedbackLive do
  use FeedbackDemoWeb, :live_view

  alias FeedbackDemo.Feedback.Entry
  alias PhoenixReplay.UI.Components

  on_mount {FeedbackDemoWeb.LiveUserAuth, :live_user_required}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FeedbackDemo.PubSub, "feedback:status_changed")
      Phoenix.PubSub.subscribe(FeedbackDemo.PubSub, "feedback:created")
    end

    {:ok, assign(socket, feedbacks: load(), selected: nil)}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    selected = Enum.find(socket.assigns.feedbacks, &(to_string(&1.id) == id))
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, selected: nil)}

  def handle_info({topic, _payload}, socket)
      when topic in [:feedback_created, :feedback_status_changed],
      do: {:noreply, assign(socket, feedbacks: load())}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("acknowledge", %{"id" => id}, socket) do
    Entry.acknowledge!(id, actor: socket.assigns.current_user)
    {:noreply, assign(socket, feedbacks: load())}
  end

  defp load, do: Entry.list_feedback!()

  def render(assigns) do
    ~H"""
    <Components.phoenix_replay_admin_assets />

    <div class="p-6 space-y-6">
      <h1 class="text-2xl font-semibold">Feedback triage</h1>

      <table class="w-full text-sm border">
        <thead class="bg-base-200 text-left">
          <tr>
            <th class="p-2">Status</th>
            <th class="p-2">Severity</th>
            <th class="p-2">Env</th>
            <th class="p-2">Description</th>
            <th class="p-2">Reported</th>
            <th class="p-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={f <- @feedbacks} class="border-t hover:bg-base-100">
            <td class="p-2">{f.status}</td>
            <td class="p-2">{f.severity}</td>
            <td class="p-2">{f.reported_on_env}</td>
            <td class="p-2 max-w-xl truncate">{f.description}</td>
            <td class="p-2 text-xs opacity-70">
              {Calendar.strftime(f.inserted_at, "%Y-%m-%d %H:%M")}
            </td>
            <td class="p-2 flex gap-2">
              <.link
                patch={~p"/admin/feedback/#{f.id}"}
                class="px-2 py-1 bg-primary text-primary-content rounded"
              >
                View
              </.link>
              <button
                :if={f.status == :new}
                phx-click="acknowledge"
                phx-value-id={f.id}
                class="px-2 py-1 bg-secondary text-secondary-content rounded"
              >
                Ack
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@selected} class="border rounded p-4 space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">
            Session {@selected.session_id}
          </h2>
          <.link patch={~p"/admin/feedback"} class="text-sm underline">close</.link>
        </div>

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-sm">
          <dt class="opacity-70">Status</dt><dd>{@selected.status}</dd>
          <dt class="opacity-70">Severity</dt><dd>{@selected.severity}</dd>
          <dt class="opacity-70">Env</dt><dd>{@selected.reported_on_env}</dd>
        </dl>

        <p class="whitespace-pre-wrap">{@selected.description}</p>

        <Components.replay_player
          id={"player-#{@selected.id}"}
          events_url={~p"/admin/feedback/events/#{@selected.session_id}"}
          height="600px"
        />
      </div>
    </div>
    """
  end
end
```

Route it inside the `ash_authentication_live_session` block so
`current_user` is available:

```elixir
scope "/", FeedbackDemoWeb do
  pipe_through :browser

  ash_authentication_live_session :authenticated_routes do
    live "/admin/feedback", Admin.FeedbackLive, :index
    live "/admin/feedback/:id", Admin.FeedbackLive, :show
  end
end
```

The detail panel fetches rrweb frames from the admin JSON endpoint
(`GET /admin/feedback/events/:session_id`) which step 3 already
mounted via `admin_routes "/feedback"`.
`phoenix_replay_admin_assets/1` emits the rrweb-player CSS/JS once
per page so the `replay_player/1` component auto-initializes on
mount (and on subsequent LV patches).

This is still intentionally minimal — extend with severity filters,
a comment thread, assign/verify/dismiss modals, etc. as your
project needs. Phase 5g will ship a full Cinder-based drop-in that
replaces all of the above.

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
