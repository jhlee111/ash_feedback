defmodule AshFeedback.Resources.Feedback.Setup do
  @moduledoc false
  # Macro-time helpers for `AshFeedback.Resources.Feedback.__using__/1`.
  # Lifts argument resolution, audio-feature detection, and the ~20-line
  # ArgumentError message out of the quote block so the macro body reads
  # as a short list of declarative sections.
  #
  # Each function here runs at the host's compile time (when the host
  # invokes `use AshFeedback.Resources.Feedback, ...`); none of it
  # generates AST. The `quote` block in the parent macro is the only
  # place where Ash DSL is emitted.

  @doc """
  Returns `true` when ADR-0001 audio narration is enabled and the
  optional `AshStorage` dep is loadable. Both conditions must hold —
  the runtime opt-in alone is meaningless without the extension.

  Uses `Application.get_env/3` rather than `compile_env/3` because
  `compile_env` cannot be called inside a `defmacro` body. The value is
  still resolved at the host's compile time.
  """
  def audio_enabled? do
    Application.get_env(:ash_feedback, :audio_enabled, false) and
      Code.ensure_loaded?(AshStorage)
  end

  @doc """
  Raises a fully-formed `ArgumentError` if audio is enabled but the
  host did not provide both `:audio_blob_resource` and
  `:audio_attachment_resource`. AshStorage's section-level DSL requires
  both — failing here surfaces the misconfiguration at compile time
  rather than a confusing DSL error from inside Spark.
  """
  def validate_audio_opts!(opts, audio_enabled?) do
    blob = Keyword.get(opts, :audio_blob_resource)
    attachment = Keyword.get(opts, :audio_attachment_resource)

    if audio_enabled? and (is_nil(blob) or is_nil(attachment)) do
      raise ArgumentError, """
      AshFeedback audio narration is enabled (config :ash_feedback,
      audio_enabled: true) but `:audio_blob_resource` and/or
      `:audio_attachment_resource` were not passed to
      `use AshFeedback.Resources.Feedback`.

      Define an AshStorage BlobResource + AttachmentResource pair in
      your host (see `AshStorage` docs and the reference shapes under
      `dev/resources/{blob,attachment}.ex` in the ash_storage repo)
      and pass both:

          use AshFeedback.Resources.Feedback,
            domain: MyApp.Feedback,
            repo: MyApp.Repo,
            audio_blob_resource: MyApp.Storage.Blob,
            audio_attachment_resource: MyApp.Storage.Attachment

      Or set `config :ash_feedback, audio_enabled: false` to disable
      audio narration.
      """
    end

    :ok
  end

  @doc """
  Returns the `notifiers:` list passed to `use Ash.Resource`. Empty
  unless the host wired a `:pubsub` module.
  """
  def notifiers(nil), do: []
  def notifiers(_pubsub_module), do: [Ash.Notifier.PubSub]

  @doc """
  Returns the `extensions:` list passed to `use Ash.Resource`.
  AshStorage is appended only when audio narration is compile-time
  enabled.
  """
  def extensions(audio_enabled?) do
    base = [AshStateMachine, AshPaperTrail.Resource]
    if audio_enabled?, do: base ++ [AshStorage], else: base
  end

  @doc """
  Builds the keyword list passed to `use Ash.Resource`. Threads
  `:otp_app` only when the host provided one (AshStorage's per-resource
  service config relies on it).
  """
  def build_use_opts(domain, audio_enabled?, pubsub_module, otp_app) do
    base = [
      domain: domain,
      data_layer: AshPostgres.DataLayer,
      extensions: extensions(audio_enabled?),
      notifiers: notifiers(pubsub_module)
    ]

    if otp_app, do: Keyword.put(base, :otp_app, otp_app), else: base
  end
end
