defmodule AshFeedback.AudioRoundTripTest do
  @moduledoc """
  End-to-end round-trip across the surface ash_feedback actually owns:

      AudioUploadsController.prepare/2
        → AshStorage Blob row (with metadata persisted at prepare time)
        → AshFeedback.Storage.submit/3 with extras.audio_clip_blob_id
          → AttachBlob change wires the blob to :audio_clip
            → feedback.audio_clip.blob.metadata["audio_start_offset_ms"]

  The HTTP transport between prepare and the bytes-PUT (presigned URL +
  AWS sigv4) is `AshStorage.Service` territory, not ours — `Service.Test`
  stubs that out. A separate Firkin / MinIO smoke is documented in the
  manual smoke checklist for sub-phase 2d.

  D2-revised: the narration start offset is persisted on the **blob**'s
  metadata map (set by `prepare_direct_upload(..., metadata: ...)`) — not
  on the attachment. The submit-side wire format only carries the blob id.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshFeedback.Controller.AudioUploadsController
  alias AshFeedback.Storage
  alias AshFeedback.Test.AudioFeedback
  alias AshFeedback.Test.StorageBlob
  alias AshFeedback.Test.StorageDomain

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()

    Application.put_env(:ash_feedback, :feedback_resource, AudioFeedback)

    Application.put_env(
      :phoenix_replay,
      :storage,
      {AshFeedback.Storage, resource: AudioFeedback, repo: AshFeedback.Test.Repo}
    )

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:phoenix_replay, :storage)
    end)

    :ok
  end

  test "prepare → submit-with-extras → blob attached + offset on blob.metadata" do
    # 1. Prepare a direct upload through the controller. The browser-side
    #    recorder JS posts here with `metadata: { audio_start_offset_ms }`.
    prepare_conn =
      conn(
        :post,
        "/audio_uploads/prepare",
        Jason.encode!(%{
          "filename" => "voice.webm",
          "content_type" => "audio/webm; codecs=opus",
          "byte_size" => 12_345,
          "metadata" => %{"audio_start_offset_ms" => 4321}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(
        Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
      )
      |> AudioUploadsController.call(AudioUploadsController.init(:prepare))

    assert prepare_conn.status == 200
    %{"blob_id" => blob_id} = Jason.decode!(prepare_conn.resp_body)

    # 2. Round-trip the blob row to confirm metadata persisted at prepare.
    blob = Ash.get!(StorageBlob, blob_id, domain: StorageDomain)
    assert blob.metadata["audio_start_offset_ms"] == 4321

    # 3. Submit feedback through the Storage adapter with extras.audio_clip_blob_id.
    #    The adapter forwards it to the :submit action; AttachBlob wires it.
    session_id = "session-#{System.unique_integer([:positive])}"

    {:ok, feedback} =
      Storage.submit(
        session_id,
        %{
          "description" => "round-trip test",
          "extras" => %{"audio_clip_blob_id" => blob_id}
        },
        %{}
      )

    # 4. Audio attachment links the prepared blob with its metadata.
    feedback = Ash.load!(feedback, [audio_clip: [:blob]], domain: StorageDomain)

    assert feedback.audio_clip
    assert feedback.audio_clip.blob_id == blob_id
    assert feedback.audio_clip.blob.id == blob_id
    assert feedback.audio_clip.blob.metadata["audio_start_offset_ms"] == 4321
  end
end
