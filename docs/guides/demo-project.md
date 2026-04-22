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

## 1. Create the Phoenix app

```bash
mix archive.install hex phx_new                    # if not already
mix phx.new feedback_demo --database postgres --binary-id --no-mailer --no-assets=false
cd feedback_demo
```

`--binary-id` matters: ash_feedback's tables use UUID primary keys,
and having the rest of your app on `binary_id` keeps FK types
consistent.

## 2. Add Ash + AshPostgres

Edit `mix.exs`:

```elixir
defp deps do
  [
    # ... existing phoenix deps ...
    {:ash, "~> 3.0"},
    {:ash_postgres, "~> 2.0"},
    {:ash_authentication, "~> 4.0"},
    {:ash_authentication_phoenix, "~> 2.0"},
    {:ash_state_machine, "~> 0.2"},
    {:ash_paper_trail, "~> 0.5"},

    # The feedback libraries
    {:phoenix_replay, github: "jhlee111/phoenix_replay", branch: "main"},
    {:ash_feedback, github: "jhlee111/ash_feedback", branch: "main"}
  ]
end
```

```bash
mix deps.get
mix ash.install
mix ash_authentication.install
```

Create the DB: `mix ecto.create`.

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

## 5. Seed a test user

```bash
iex -S mix phx.server
```

In IEx (once the auth resource is in place — see
`AshAuthentication.Phoenix` docs for generator commands):

```elixir
{:ok, user} =
  FeedbackDemo.Accounts.User
  |> Ash.Changeset.for_create(:register, %{
    email: "qa@example.com",
    password: "password123",
    password_confirmation: "password123"
  })
  |> Ash.create(authorize?: false)
```

Sign in via the AshAuthentication sign-in page at
`http://localhost:4000/sign-in`.

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

## 8. Minimal admin LiveView (placeholder until Phase 5g)

Until [`AshFeedback.UI.AdminLive`](../plans/5g-admin-live.md) ships,
drop this ~80-line LV into your app as a starting point. It lists
feedbacks in a plain table + shows the action buttons inline.

`lib/feedback_demo_web/live/admin/feedback_live.ex`:

```elixir
defmodule FeedbackDemoWeb.Admin.FeedbackLive do
  use FeedbackDemoWeb, :live_view

  alias FeedbackDemo.Feedback.Entry

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FeedbackDemo.PubSub, "feedback:status_changed")
      Phoenix.PubSub.subscribe(FeedbackDemo.PubSub, "feedback:created")
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
live "/admin/feedback", FeedbackDemoWeb.Admin.FeedbackLive
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
