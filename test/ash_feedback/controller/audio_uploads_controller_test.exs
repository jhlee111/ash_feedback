defmodule AshFeedback.Controller.AudioUploadsControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshFeedback.Controller.AudioUploadsController

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()

    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.StorageFeedback)
    on_exit(fn -> Application.delete_env(:ash_feedback, :feedback_resource) end)

    :ok
  end

  defp call(params) do
    conn(:post, "/prepare", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(
      Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
    )
    |> AudioUploadsController.call(AudioUploadsController.init(:prepare))
  end

  test "POST /prepare returns blob_id, url, method, fields" do
    conn =
      call(%{
        "filename" => "voice.webm",
        "content_type" => "audio/webm; codecs=opus",
        "byte_size" => 12_345
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["blob_id"])
    assert is_binary(body["url"])
    assert body["method"] in ["put", "post"]
    assert is_map(body["fields"])
  end

  test "POST /prepare with metadata persists it on the blob row" do
    conn =
      call(%{
        "filename" => "voice.webm",
        "content_type" => "audio/webm; codecs=opus",
        "byte_size" => 12_345,
        "metadata" => %{"audio_start_offset_ms" => 1234}
      })

    assert conn.status == 200
    blob_id = Jason.decode!(conn.resp_body)["blob_id"]
    blob = Ash.get!(AshFeedback.Test.StorageBlob, blob_id, domain: AshFeedback.Test.StorageDomain)
    assert blob.metadata["audio_start_offset_ms"] == 1234
  end

  test "POST /prepare returns 422 when filename is missing" do
    conn = call(%{"content_type" => "audio/webm", "byte_size" => 1})
    assert conn.status == 422
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end
end
