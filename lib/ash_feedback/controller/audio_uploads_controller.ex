defmodule AshFeedback.Controller.AudioUploadsController do
  @moduledoc """
  Mints presigned URLs for direct upload of audio narration blobs
  via AshStorage. POST `/prepare` returns the URL + a Blob row id;
  the client PUTs (or POSTs) bytes to that URL and submits feedback
  with `extras: { audio_clip_blob_id: <id> }`.

  An optional `metadata` field on the POST body is passed through to
  AshStorage.Operations.prepare_direct_upload/3 as the blob's
  metadata. Audio narration uses this to persist
  `audio_start_offset_ms` on the blob row at upload time.

  Mount in your Phoenix router:

      post "/audio_uploads/prepare", AshFeedback.Controller.AudioUploadsController, :prepare

  The host application must configure `:feedback_resource`:

      config :ash_feedback, :feedback_resource, MyApp.Feedback.Entry
  """

  use Phoenix.Controller, formats: [:json]

  def prepare(conn, %{"filename" => filename} = params) do
    feedback_resource = AshFeedback.Config.feedback_resource!()
    content_type = Map.get(params, "content_type", "application/octet-stream")
    byte_size = Map.get(params, "byte_size", 0)
    metadata = stringify_keys(Map.get(params, "metadata") || %{})

    case AshStorage.Operations.prepare_direct_upload(
           feedback_resource,
           :audio_clip,
           filename: filename,
           content_type: content_type,
           byte_size: byte_size,
           metadata: metadata
         ) do
      {:ok, %{blob: blob, url: url, method: method} = info} ->
        json(conn, %{
          blob_id: blob.id,
          url: url,
          method: to_string(method),
          fields: Map.get(info, :fields, %{})
        })

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: Exception.message(error)})
    end
  end

  def prepare(conn, _params) do
    conn |> put_status(422) |> json(%{error: "filename is required"})
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
