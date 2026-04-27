defmodule AshFeedback.Config do
  @moduledoc """
  Runtime configuration accessors for ash_feedback. Hosts set these in
  `config/config.exs`:

      config :ash_feedback,
        feedback_resource: MyApp.Feedback.Entry,
        audio_attachment_resource: MyApp.Storage.Attachment

  These helpers raise with actionable error messages so misconfigured
  hosts get a clear pointer rather than a cryptic `Ash.Error.Query.NotFound`
  later.
  """

  def feedback_resource! do
    case Application.get_env(:ash_feedback, :feedback_resource) do
      nil ->
        raise """
        ash_feedback: :feedback_resource is not configured.

        Set it in your host config:

            config :ash_feedback, :feedback_resource, MyApp.Feedback.Entry

        Where `MyApp.Feedback.Entry` is the concrete resource that
        `use AshFeedback.Resources.Feedback`.
        """

      resource ->
        resource
    end
  end

  def audio_attachment_resource! do
    case Application.get_env(:ash_feedback, :audio_attachment_resource) do
      nil ->
        raise """
        ash_feedback: :audio_attachment_resource is not configured.

        Set it in your host config:

            config :ash_feedback, :audio_attachment_resource, MyApp.Storage.Attachment

        Where `MyApp.Storage.Attachment` is your AshStorage AttachmentResource.
        """

      resource ->
        resource
    end
  end

  def audio_max_seconds do
    Application.get_env(:ash_feedback, :audio_max_seconds, 300)
  end

  @doc """
  Signed-URL TTL for audio download redirects.

  Default 1800 seconds (30 minutes) — long enough that scrub/pause cycles
  on a single admin mount don't outrun the URL; short enough to bound token
  exposure. Hosts override per policy.
  """
  def audio_download_url_ttl_seconds do
    Application.get_env(:ash_feedback, :audio_download_url_ttl_seconds, 1800)
  end
end
