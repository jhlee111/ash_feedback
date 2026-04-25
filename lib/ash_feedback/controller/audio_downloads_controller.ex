defmodule AshFeedback.Controller.AudioDownloadsController do
  @moduledoc """
  302-redirects `GET /audio_downloads/:blob_id` to a signed URL minted
  by AshStorage. Expects an admin-side authorization layer in the host
  pipeline — ash_feedback adds none.

  ## Service resolution

  Given the host's `:feedback_resource` and the `:audio_clip` attachment:

    1. `AshStorage.Info.attachment/2` resolves the attachment definition.
    2. `AshStorage.Info.service_for_attachment/2` returns
       `{service_mod, base_service_opts}` honoring the standard four-step
       config precedence (per-attachment app config → DSL → resource app
       config → resource DSL).
    3. The blob's persisted `service_opts` (from
       `AshStorage.BlobResource.Calculations.ParsedServiceOpts`) are
       merged on top, then `:expires_in` is set to the configured TTL.
    4. The merged opts are wrapped in an `AshStorage.Service.Context`
       and the service module's `url/2` callback mints the URL.

  TTL via `AshFeedback.Config.audio_download_url_ttl_seconds/0`
  (default 1800s, override with
  `config :ash_feedback, :audio_download_url_ttl_seconds, ttl`).

  ## Mounting

      get "/audio_downloads/:blob_id",
          AshFeedback.Controller.AudioDownloadsController,
          :show

  Or mount via `AshFeedback.Router.audio_routes/1` which co-locates this
  with the prepare endpoint.
  """

  use Phoenix.Controller, formats: [:json]

  alias AshFeedback.Config
  alias AshStorage.Info, as: StorageInfo
  alias AshStorage.Service.Context

  def show(conn, %{"blob_id" => blob_id}) do
    case fetch_blob(blob_id) do
      {:ok, blob} ->
        url = signed_url_for(blob, ttl: Config.audio_download_url_ttl_seconds())
        conn |> put_resp_header("location", url) |> send_resp(302, "")

      :error ->
        conn |> put_status(404) |> json(%{error: "blob not found"})
    end
  end

  defp fetch_blob(blob_id) do
    feedback_resource = Config.feedback_resource!()
    blob_resource = StorageInfo.storage_blob_resource!(feedback_resource)

    case Ash.get(blob_resource, blob_id, load: [:parsed_service_opts]) do
      {:ok, blob} -> {:ok, blob}
      {:error, _} -> :error
    end
  end

  defp signed_url_for(blob, opts) do
    feedback_resource = Config.feedback_resource!()
    {:ok, attachment} = StorageInfo.attachment(feedback_resource, :audio_clip)

    {:ok, {service_mod, base_service_opts}} =
      StorageInfo.service_for_attachment(feedback_resource, attachment)

    service_opts =
      base_service_opts
      |> Keyword.merge(blob.parsed_service_opts || [])
      |> Keyword.put(:expires_in, opts[:ttl])

    ctx = Context.new(service_opts, resource: feedback_resource, attachment: attachment)
    service_mod.url(blob.key, ctx)
  end
end
