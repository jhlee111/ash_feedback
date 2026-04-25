defmodule AshFeedback.Controller.AudioDownloadsControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshFeedback.Controller.AudioDownloadsController

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()

    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.StorageFeedback)
    on_exit(fn -> Application.delete_env(:ash_feedback, :feedback_resource) end)

    :ok
  end

  defp seed_blob! do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.StorageFeedback,
        :audio_clip,
        filename: "voice.webm",
        content_type: "audio/webm; codecs=opus",
        byte_size: 1024
      )

    blob
  end

  defp call(blob_id) do
    conn(:get, "/audio_downloads/#{blob_id}")
    |> Map.put(:path_params, %{"blob_id" => blob_id})
    |> Map.put(:params, %{"blob_id" => blob_id})
    |> AudioDownloadsController.call(AudioDownloadsController.init(:show))
  end

  test "GET /audio_downloads/:blob_id returns 302 with a non-empty Location" do
    blob = seed_blob!()

    conn = call(blob.id)

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert is_binary(location) and byte_size(location) > 0
  end

  test "GET /audio_downloads/:blob_id returns 404 for an unknown blob id" do
    conn = call(Ecto.UUID.generate())

    assert conn.status == 404
  end
end
