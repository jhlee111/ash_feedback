defmodule AshFeedback.Controller.AudioUploadsController do
  @moduledoc """
  Mints presigned URLs for direct upload of audio narration blobs
  via AshStorage. POST `/prepare` returns the URL + a Blob row id;
  the client PUTs (or POSTs) bytes to that URL and submits feedback
  with `extras: { audio_clip_blob_id: <id> }`.

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

    case AshStorage.Operations.prepare_direct_upload(
           feedback_resource,
           :audio_clip,
           filename: filename,
           content_type: content_type,
           byte_size: byte_size
         ) do
      {:ok, %{blob: blob, url: url, method: method} = info} ->
        json(conn, %{
          blob_id: blob.id,
          url: url,
          method: to_string(method),
          fields: Map.get(info, :fields, %{})
        })

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: error_message(error)})
    end
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  def prepare(conn, _params) do
    conn |> put_status(422) |> json(%{error: "filename is required"})
  end
end
