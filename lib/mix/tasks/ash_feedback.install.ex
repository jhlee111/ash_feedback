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
        schema: [],
        composes: ["phoenix_replay.install", "ash.gen.domain"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_storage()
      |> generate_feedback_domain()
      |> add_resources_to_domain()
      |> Igniter.add_notice("""

      ash_feedback install — Phase 2 complete.

      Next steps (manual until later phases of 5f land):

        See README "Installation" — steps 5 onward — for the
        AshStorage Blob + Attachment + service config, the
        concrete Feedback resource, and `mix ash.codegen` +
        `mix ash.migrate`.
      """)
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

    # Adds `MyApp.Feedback.Entry` (and its AshPaperTrail-generated
    # `Version` companion) to the domain's `resources` block.
    # `Ash.Domain.Igniter.add_resource_reference/3` is idempotent —
    # it skips if the reference is already there.
    defp add_resources_to_domain(igniter) do
      domain = feedback_domain_module(igniter)
      entry = Module.concat([domain, "Entry"])
      version = Module.concat([entry, "Version"])

      igniter
      |> Ash.Domain.Igniter.add_resource_reference(domain, entry)
      |> Ash.Domain.Igniter.add_resource_reference(domain, version)
    end

    defp feedback_domain_module(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      Module.concat([host_module_alias(app_name), "Feedback"])
    end
  end
end
