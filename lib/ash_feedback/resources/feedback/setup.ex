defmodule AshFeedback.Resources.Feedback.Setup do
  @moduledoc false
  # Macro-time helpers for `AshFeedback.Resources.Feedback.__using__/1`.
  # Lifts argument resolution and the multi-line ArgumentError message
  # out of the quote block so the macro body reads as a short list of
  # declarative sections.
  #
  # Each function here runs at the host's compile time (when the host
  # invokes `use AshFeedback.Resources.Feedback, ...`); none of it
  # generates AST. The `quote` block in the parent macro is the only
  # place where Ash DSL is emitted.

  @doc """
  Raises a fully-formed `ArgumentError` if the host did not pass both
  `:audio_blob_resource` and `:audio_attachment_resource`. Audio
  narration is core (ADR-0001 Question B addendum 2026-04-26): every
  host must provide an AshStorage `Blob` + `Attachment` pair.

  AshStorage's section-level DSL requires both — failing here surfaces
  the misconfiguration at compile time rather than as a confusing DSL
  error from inside Spark.
  """
  def validate_audio_opts!(opts) do
    blob = Keyword.get(opts, :audio_blob_resource)
    attachment = Keyword.get(opts, :audio_attachment_resource)

    if is_nil(blob) or is_nil(attachment) do
      raise ArgumentError, """
      AshFeedback requires audio narration storage resources but
      `:audio_blob_resource` and/or `:audio_attachment_resource` were
      not passed to `use AshFeedback.Resources.Feedback`.

      Define an AshStorage `BlobResource` + `AttachmentResource` pair
      in your host (see the audio-narration guide and the AshStorage
      docs) and pass both:

          use AshFeedback.Resources.Feedback,
            domain: MyApp.Feedback,
            repo: MyApp.Repo,
            audio_blob_resource: MyApp.Storage.Blob,
            audio_attachment_resource: MyApp.Storage.Attachment
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
  AshStorage is always present — audio narration is core.
  """
  def extensions do
    [AshStateMachine, AshPaperTrail.Resource, AshStorage]
  end

  @doc """
  Builds the keyword list passed to `use Ash.Resource`. Threads
  `:otp_app` only when the host provided one (AshStorage's per-resource
  service config relies on it).
  """
  def build_use_opts(domain, pubsub_module, otp_app) do
    base = [
      domain: domain,
      data_layer: AshPostgres.DataLayer,
      extensions: extensions(),
      notifiers: notifiers(pubsub_module)
    ]

    if otp_app, do: Keyword.put(base, :otp_app, otp_app), else: base
  end
end
