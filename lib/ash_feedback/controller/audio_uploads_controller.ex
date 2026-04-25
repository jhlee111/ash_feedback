defmodule AshFeedback.Controller.AudioUploadsController do
  @moduledoc """
  Mints presigned URLs for direct upload of audio narration blobs
  via AshStorage. POST `/prepare` returns the URL + a Blob row id;
  the client PUTs (or POSTs) bytes to that URL and submits feedback
  with `extras: { audio_clip_blob_id: <id> }`.

  An optional `metadata` field on the POST body is passed through to
  `AshStorage.Operations.prepare_direct_upload/3` as the blob's
  metadata. Audio narration uses this to persist
  `audio_start_offset_ms` on the blob row at upload time.

  ## Usage

  Mount this controller in your Phoenix router:

      post "/audio_uploads/prepare", AshFeedback.Controller.AudioUploadsController, :prepare

  The host application must configure `:feedback_resource`:

      config :ash_feedback, :feedback_resource, MyApp.Feedback.Entry
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(action) when is_atom(action), do: action
  def init(_opts), do: :prepare

  @impl Plug
  def call(conn, :prepare), do: prepare(conn, fetch_params(conn))
  def call(conn, _), do: prepare(conn, fetch_params(conn))

  defp fetch_params(conn) do
    conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"]))
    conn.body_params
  end

  @doc """
  POST /prepare

  Accepts JSON body:
    - `filename` (string, required) - original filename
    - `content_type` (string, optional) - MIME type
    - `byte_size` (integer, optional) - file size in bytes
    - `metadata` (map, optional) - arbitrary metadata persisted on the blob row

  Returns JSON:
    - `blob_id` - UUID of the created Blob record
    - `url` - presigned upload URL
    - `method` - HTTP method to use ("put" or "post")
    - `fields` - additional form fields (for S3 multipart POST)
  """
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
      {:ok, upload_info} ->
        blob = upload_info.blob

        body =
          Jason.encode!(%{
            blob_id: blob.id,
            url: upload_info.url,
            method: to_string(upload_info.method),
            fields: Map.get(upload_info, :fields, %{})
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, error} ->
        body = Jason.encode!(%{error: to_string(error)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, body)
    end
  end

  def prepare(conn, _params) do
    body = Jason.encode!(%{error: "filename is required"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, body)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
