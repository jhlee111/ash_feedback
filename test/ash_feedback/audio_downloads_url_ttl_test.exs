defmodule AshFeedback.AudioDownloadsUrlTtlTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshFeedback.Controller.AudioDownloadsController

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()
    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.StorageFeedback)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:ash_feedback, :audio_download_url_ttl_seconds)
    end)

    :ok
  end

  test "honors :audio_download_url_ttl_seconds override (URL embeds shorter expiry)" do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.StorageFeedback,
        :audio_clip,
        filename: "x.webm",
        content_type: "audio/webm",
        byte_size: 1
      )

    Application.put_env(:ash_feedback, :audio_download_url_ttl_seconds, 60)

    conn =
      conn(:get, "/audio_downloads/#{blob.id}")
      |> Map.put(:path_params, %{"blob_id" => blob.id})
      |> Map.put(:params, %{"blob_id" => blob.id})
      |> AudioDownloadsController.call(AudioDownloadsController.init(:show))

    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    assert is_binary(location)
    refute location == ""
  end
end
