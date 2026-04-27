if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshFeedback.Install do
    @example "mix igniter.install ash_feedback"
    @shortdoc "Installs ash_feedback into a Phoenix + Ash project"

    @moduledoc """
    Installs `ash_feedback` into a Phoenix + Ash project.

    ## Recommended

        #{@example}

    Igniter adds `ash_feedback` to your deps, fetches it, and runs
    this installer on your codebase. Run `phoenix_replay`'s installer
    first — `ash_feedback`'s installer assumes the
    `:phoenix_replay :storage` key is already present and flips it to
    point at `AshFeedback.Storage`.

    ## What it does

    Phase 1 (current):

      1. Flips the `:phoenix_replay :storage` config from
         `PhoenixReplay.Storage.Ecto` to `{AshFeedback.Storage,
         resource: <HostApp>.Feedback.Entry, repo: <HostApp>.Repo}`.

    Phase 2+ (proposed in `docs/plans/5f-igniter-installer.md`):

      - Generate `<HostApp>.Feedback` domain + register in
        `:ash_domains`
      - Generate concrete `<HostApp>.Feedback.Entry` resource
      - Generate AshStorage `Blob` + `Attachment` + service config
      - Optional `<HostApp>.Feedback.Comment` resource
      - Notice with follow-up commands (`mix ash.codegen`,
        `mix ash.migrate`)

    ## Manual install

    If you've already added `{:ash_feedback, ...}` to your `mix.exs`
    yourself:

        mix ash_feedback.install
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_feedback,
        example: @example,
        schema: [with_admin: :boolean],
        composes: [
          "ash.install",
          "ash_postgres.install",
          "phoenix_replay.install",
          "ash.gen.domain"
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      with_admin? = igniter.args.options[:with_admin] || false

      igniter
      # Ash + AshPostgres convert the host's Repo into an AshPostgres
      # Repo (required by every resource we generate); compose them
      # before our own patchers so the macro's `data_layer:
      # AshPostgres.DataLayer` works on a fresh phx.new.
      |> Igniter.compose_task("ash.install", [])
      |> Igniter.compose_task("ash_postgres.install", [])
      |> configure_storage()
      |> generate_feedback_domain()
      |> generate_audio_blob_resource()
      |> generate_audio_attachment_resource()
      |> generate_feedback_entry_resource()
      |> generate_feedback_comment_resource()
      |> add_resources_to_domain()
      |> configure_audio_storage_service()
      |> maybe_generate_admin_live(with_admin?)
      |> Igniter.add_notice(final_notice(with_admin?))
    end

    defp final_notice(false) do
      """

      ash_feedback install complete.

      Two follow-up commands to finish bootstrapping:

        mix ash.codegen add_feedback_paper_trail
        mix ash.migrate

      Then drop the Phoenix replay widget into your root layout:

        <PhoenixReplay.UI.Components.phoenix_replay_widget
          base_path="/api/feedback"
          csrf_token={get_csrf_token()}
          audio_default={:on}
        />

      And mount the audio routes:

        scope "/api" do
          pipe_through :api
          AshFeedback.Router.audio_routes(path: "/audio")
        end

      See `ash_feedback`'s README "Installation" for the full
      walkthrough. Need an admin triage UI? Re-run with --with-admin
      and the installer will scaffold one.
      """
    end

    defp final_notice(true) do
      """

      ash_feedback install complete (with admin scaffold).

      Two follow-up commands to finish bootstrapping:

        mix ash.codegen add_feedback_paper_trail
        mix ash.migrate

      Drop the Phoenix replay widget into your root layout:

        <PhoenixReplay.UI.Components.phoenix_replay_widget
          base_path="/api/feedback"
          csrf_token={get_csrf_token()}
          audio_default={:on}
        />

      Mount the audio routes:

        scope "/api" do
          pipe_through :api
          AshFeedback.Router.audio_routes(path: "/audio")
        end

      Mount the admin LiveView (in your authenticated browser scope):

        live "/admin/feedback", Admin.FeedbackLive, :index
        live "/admin/feedback/:id", Admin.FeedbackLive, :show

      The scaffolded LiveView includes a TODO at the on_mount call —
      wire your authentication pipeline before deploying.
      """
    end

    # --- Storage config patcher ---------------------------------------

    defp configure_storage(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      host = host_module_alias(app_name)
      feedback_resource = Module.concat([host, "Feedback", "Entry"])
      repo = Module.concat([host, "Repo"])

      storage_ast = storage_value_ast(feedback_resource, repo)

      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :phoenix_replay,
        [:storage],
        {:code, storage_ast},
        updater: fn zipper ->
          {:ok, Igniter.Code.Common.replace_code(zipper, storage_ast)}
        end
      )
    end

    # Build the `{AshFeedback.Storage, resource: ..., repo: ...}` AST
    # via Sourceror so the rendered output has stable formatting and
    # the host-app module aliases are real `__aliases__` nodes.
    defp storage_value_ast(feedback_resource, repo) do
      Sourceror.parse_string!("""
      {AshFeedback.Storage,
       resource: #{inspect(feedback_resource)},
       repo: #{inspect(repo)}}
      """)
    end

    defp host_module_alias(app_name) do
      app_name
      |> Atom.to_string()
      |> Macro.camelize()
      |> List.wrap()
      |> Module.concat()
    end

    # --- Domain generation patcher ------------------------------------

    # Composes `mix ash.gen.domain` to create `<HostApp>.Feedback` and
    # add it to `:my_app, ash_domains`. `--ignore-if-exists` keeps the
    # patcher idempotent on re-runs.
    defp generate_feedback_domain(igniter) do
      domain = feedback_domain_module(igniter)

      Igniter.compose_task(igniter, "ash.gen.domain", [
        inspect(domain),
        "--ignore-if-exists"
      ])
    end

    # --- Domain resource-list patcher ---------------------------------

    # Adds the resources generated by this installer to the domain's
    # `resources` block. Comment is only registered when a User module
    # exists — Comment generation is gated on the same check, so the
    # domain reference would point at a missing module otherwise.
    # `Ash.Domain.Igniter.add_resource_reference/3` is idempotent.
    defp add_resources_to_domain(igniter) do
      domain = feedback_domain_module(igniter)
      app_name = Igniter.Project.Application.app_name(igniter)

      base = [
        feedback_entry_module(igniter),
        Module.concat([feedback_entry_module(igniter), "Version"]),
        audio_blob_module(igniter),
        audio_attachment_module(igniter)
      ]

      resources =
        if host_has_user?(igniter, app_name) do
          base ++ [feedback_comment_module(igniter)]
        else
          base
        end

      Enum.reduce(resources, igniter, fn resource, acc ->
        Ash.Domain.Igniter.add_resource_reference(acc, domain, resource)
      end)
    end

    # --- AshStorage Blob + Attachment generators ----------------------

    # Generates `<HostApp>.Storage.Blob`, the AshStorage `BlobResource`
    # that backs audio narration uploads. ADR-0001 Question A: hosts
    # own the Blob shape because the storage backend (S3/Disk/MinIO),
    # bucket, and auth strategy are host-specific. We emit a minimal
    # uuid-id Postgres-backed shape that the host can extend with
    # AshOban triggers, custom auth, etc.
    defp generate_audio_blob_resource(igniter) do
      blob = audio_blob_module(igniter)
      domain = feedback_domain_module(igniter)
      repo = host_repo_module(igniter)

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, blob)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, blob, """
        @moduledoc \"\"\"
        AshStorage blob resource backing audio narration uploads on
        feedback rows. Generated by `mix ash_feedback.install`. Host
        owns the shape — extend with AshOban triggers, alternative
        auth, etc., as your app needs.
        \"\"\"
        use Ash.Resource,
          domain: #{inspect(domain)},
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStorage.BlobResource]

        postgres do
          table "blobs"
          repo #{inspect(repo)}
        end

        blob do
        end

        attributes do
          uuid_primary_key :id
        end
        """)
      end
    end

    # Generates `<HostApp>.Storage.Attachment`, the AshStorage
    # `AttachmentResource` that joins blobs to feedback rows via the
    # `:audio_clip` has_one_attached on `<HostApp>.Feedback.Entry`.
    defp generate_audio_attachment_resource(igniter) do
      attachment = audio_attachment_module(igniter)
      blob = audio_blob_module(igniter)
      entry = feedback_entry_module(igniter)
      domain = feedback_domain_module(igniter)
      repo = host_repo_module(igniter)

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, attachment)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, attachment, """
        @moduledoc \"\"\"
        AshStorage attachment resource — joins
        `#{inspect(blob)}` rows to `#{inspect(entry)}` rows via the
        `:audio_clip` has_one_attached declaration emitted by
        `AshFeedback.Resources.Feedback`. Generated by
        `mix ash_feedback.install`.
        \"\"\"
        use Ash.Resource,
          domain: #{inspect(domain)},
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStorage.AttachmentResource]

        postgres do
          table "attachments"
          repo #{inspect(repo)}

          references do
            reference :feedback, on_delete: :delete
          end
        end

        attachment do
          blob_resource #{inspect(blob)}
          belongs_to_resource :feedback, #{inspect(entry)}
        end

        attributes do
          uuid_primary_key :id
        end
        """)
      end
    end

    # --- Storage service config patcher (dev) -------------------------

    # Adds an `AshStorage.Service.Disk` service config under
    # `config :host_app, HostApp.Feedback.Entry` in `dev.exs`. Disk is
    # the right default for `mix ash_feedback.install` — no AWS creds
    # required, no infra to provision; works out of the box on a fresh
    # Phoenix scaffold.
    defp configure_audio_storage_service(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      entry = feedback_entry_module(igniter)

      service_ast =
        Sourceror.parse_string!("""
        [
          service:
            {AshStorage.Service.Disk,
             root: Path.join(File.cwd!(), "tmp/uploads"),
             base_url: "http://localhost:4000",
             direct_upload: true}
        ]
        """)

      Igniter.Project.Config.configure(
        igniter,
        "dev.exs",
        app_name,
        [entry, :storage],
        {:code, service_ast}
      )
    end

    # --- Concrete Feedback resource generator -------------------------

    # Generates `<HostApp>.Feedback.Entry`, the host's concrete
    # Feedback resource that calls `use AshFeedback.Resources.Feedback`.
    # Detects an `<HostApp>.Accounts.User` module to wire the
    # assignee_resource (and the AshAuthentication/non-AshAuthentication
    # split is irrelevant — we just need a User to point at). When no
    # User is found, the assignee opts are commented out and the host
    # fills in later.
    defp generate_feedback_entry_resource(igniter) do
      entry = feedback_entry_module(igniter)
      domain = feedback_domain_module(igniter)
      repo = host_repo_module(igniter)
      blob = audio_blob_module(igniter)
      attachment = audio_attachment_module(igniter)
      app_name = Igniter.Project.Application.app_name(igniter)

      {entry_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, entry)

      if entry_exists? do
        igniter
      else
        {opts_lines, igniter} = build_use_feedback_opts(igniter, app_name, domain, repo, blob, attachment)

        Igniter.Project.Module.create_module(igniter, entry, """
        @moduledoc \"\"\"
        Concrete Feedback resource. Generated by
        `mix ash_feedback.install`. The macro emits the full Ash
        resource — attributes, state machine, paper trail, code
        interface, PubSub notifier, and audio narration wiring.
        \"\"\"
        use AshFeedback.Resources.Feedback,
        #{opts_lines}
        """)
      end
    end

    # Builds the comma-separated `use AshFeedback.Resources.Feedback`
    # opts as a single string with leading two-space indent on each
    # line. Optional opts (assignee_resource, pubsub) are included only
    # when their dependency modules exist in the host's source — keeps
    # the emitted code parseable by Sourceror, and avoids referring to
    # modules the host hasn't created yet.
    defp build_use_feedback_opts(igniter, app_name, domain, repo, blob, attachment) do
      user_module = Module.concat([host_module_alias(app_name), "Accounts", "User"])
      pubsub_module = Module.concat([host_module_alias(app_name), "PubSub"])

      {user_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, user_module)
      {pubsub_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, pubsub_module)

      lines =
        [
          "  otp_app: #{inspect(app_name)}",
          "  domain: #{inspect(domain)}",
          "  repo: #{inspect(repo)}",
          if(user_exists?, do: "  assignee_resource: #{inspect(user_module)}"),
          if(pubsub_exists?, do: "  pubsub: #{inspect(pubsub_module)}"),
          "  audio_blob_resource: #{inspect(blob)}",
          "  audio_attachment_resource: #{inspect(attachment)}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(",\n")

      {lines, igniter}
    end

    # --- Optional FeedbackComment resource generator ------------------

    # Generates `<HostApp>.Feedback.Comment`. Always emits the file —
    # if the host doesn't want the comment thread feature they can
    # delete the module + drop its line from the domain's resources
    # block. We don't gate behind a prompt because Igniter installers
    # are commonly invoked non-interactively (CI, scripted setups).
    defp generate_feedback_comment_resource(igniter) do
      comment = feedback_comment_module(igniter)
      entry = feedback_entry_module(igniter)
      domain = feedback_domain_module(igniter)
      repo = host_repo_module(igniter)
      app_name = Igniter.Project.Application.app_name(igniter)

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, comment)

      cond do
        exists? ->
          igniter

        not host_has_user?(igniter, app_name) ->
          # FeedbackComment.__using__/1 requires :author_resource. Skip
          # generation when the host doesn't have a User module yet —
          # surface a notice so the host knows to come back and add the
          # Comment resource by hand once their auth model is in place.
          Igniter.add_notice(igniter, """

          Skipped FeedbackComment generation — `:author_resource` is
          required by `AshFeedback.Resources.FeedbackComment` and no
          `<HostApp>.Accounts.User` module was found in the project.

          Add a User resource (e.g. via `mix igniter.install ash_authentication_phoenix`)
          and re-run `mix ash_feedback.install`, or create the Comment
          resource manually following the README "Manual install" — step 7.
          """)

        true ->
          {opts_lines, igniter} =
            build_use_feedback_comment_opts(igniter, app_name, domain, repo, entry)

          Igniter.Project.Module.create_module(igniter, comment, """
          @moduledoc \"\"\"
          Append-only feedback comments. Generated by
          `mix ash_feedback.install`. Delete this module and remove
          the corresponding `resource ...` line from
          `#{inspect(domain)}` if you do not need the comment thread
          feature.
          \"\"\"
          use AshFeedback.Resources.FeedbackComment,
          #{opts_lines}
          """)
      end
    end

    defp host_has_user?(igniter, app_name) do
      user_module = Module.concat([host_module_alias(app_name), "Accounts", "User"])
      {exists?, _igniter} = Igniter.Project.Module.module_exists(igniter, user_module)
      exists?
    end

    # Same pattern as build_use_feedback_opts/6 — emits author_resource
    # (always — required by the macro; we only call this when the User
    # module exists) and pubsub conditionally.
    defp build_use_feedback_comment_opts(igniter, app_name, domain, repo, entry) do
      user_module = Module.concat([host_module_alias(app_name), "Accounts", "User"])
      pubsub_module = Module.concat([host_module_alias(app_name), "PubSub"])

      {pubsub_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, pubsub_module)

      lines =
        [
          "  domain: #{inspect(domain)}",
          "  repo: #{inspect(repo)}",
          "  feedback_resource: #{inspect(entry)}",
          "  author_resource: #{inspect(user_module)}",
          if(pubsub_exists?, do: "  pubsub: #{inspect(pubsub_module)}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(",\n")

      {lines, igniter}
    end

    defp feedback_domain_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      Module.concat([host_module_alias(app_name), "Feedback"])
    end

    defp feedback_entry_module(igniter) do
      Module.concat([feedback_domain_module(igniter), "Entry"])
    end

    defp feedback_comment_module(igniter) do
      Module.concat([feedback_domain_module(igniter), "Comment"])
    end

    # --- Admin LiveView generator (--with-admin) ----------------------

    # Emits `<HostAppWeb>.Admin.FeedbackLive`, a 140-line drop-in
    # admin LiveView modeled on the demo's `feedback_live.ex`. The
    # template uses plain HEEx (no Cinder yet) — feedback inbox table
    # + selected-row detail panel + replay player + audio playback.
    # Host owns the file from then on; library updates do not flow
    # through. Idempotent — skips when the module already exists.
    defp maybe_generate_admin_live(igniter, false), do: igniter

    defp maybe_generate_admin_live(igniter, true) do
      module = admin_feedback_live_module(igniter)
      app_name = Igniter.Project.Application.app_name(igniter)
      web_module = host_web_module(igniter)
      entry = feedback_entry_module(igniter)
      pubsub = Module.concat([host_module_alias(app_name), "PubSub"])

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(
          igniter,
          module,
          admin_live_template(web_module, entry, pubsub)
        )
      end
    end

    defp admin_feedback_live_module(igniter) do
      Module.concat([host_web_module(igniter), "Admin", "FeedbackLive"])
    end

    defp host_web_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)

      app_name
      |> Atom.to_string()
      |> Macro.camelize()
      |> Kernel.<>("Web")
      |> List.wrap()
      |> Module.concat()
    end

    defp admin_live_template(web_module, entry, pubsub) do
      """
      @moduledoc \"\"\"
      Admin triage LiveView for feedback rows. Generated by
      `mix ash_feedback.install --with-admin`. You own this file —
      library updates won't flow through. Customize the table,
      filters, action set, and styling to fit your app.
      \"\"\"
      use #{inspect(web_module)}, :live_view

      alias #{inspect(entry)}
      alias AshFeedbackWeb.Components.AudioPlayback
      alias PhoenixReplay.UI.Components

      # TODO: wire your authentication pipeline. AshAuthentication-style
      # apps typically use:
      #
      #     on_mount {#{inspect(web_module)}.LiveUserAuth, :live_user_required}
      #
      # If you're not using AshAuthentication, replace with your own
      # on_mount module.

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(#{inspect(pubsub)}, "feedback:status_changed")
          Phoenix.PubSub.subscribe(#{inspect(pubsub)}, "feedback:created")
        end

        {:ok,
         socket
         |> assign(feedbacks: load(), selected: nil)
         |> assign(audio_url: nil)}
      end

      def handle_params(%{"id" => id}, _uri, socket) do
        # `:audio_clip` + its blob need explicit loading — the list
        # cache doesn't carry the attachment.
        selected = Entry.get_feedback!(id, load: [audio_clip: [:blob]])

        {:noreply,
         socket
         |> assign(selected: selected)
         |> assign(audio_url: audio_url(selected))}
      end

      def handle_params(_params, _uri, socket),
        do:
          {:noreply,
           socket
           |> assign(selected: nil)
           |> assign(audio_url: nil)}

      defp audio_url(%{audio_clip: %{blob: %{id: blob_id}}}),
        do: "/audio_uploads/audio_downloads/" <> blob_id

      defp audio_url(_), do: nil

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
        ~H\"\"\"
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
                    patch={~p"/admin/feedback/\#{f.id}"}
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
              id={"player-\#{@selected.id}"}
              session_id={@selected.session_id}
              events_url={~p"/admin/feedback/events/\#{@selected.session_id}"}
              height={600}
            />

            <AudioPlayback.audio_playback
              audio_url={@audio_url}
              session_id={@selected.session_id}
            />
          </div>
        </div>
        \"\"\"
      end
      """
    end

    defp audio_blob_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      Module.concat([host_module_alias(app_name), "Storage", "Blob"])
    end

    defp audio_attachment_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      Module.concat([host_module_alias(app_name), "Storage", "Attachment"])
    end

    defp host_repo_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      Module.concat([host_module_alias(app_name), "Repo"])
    end
  end
end
