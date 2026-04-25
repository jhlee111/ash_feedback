defmodule AshFeedback.AudioDownloadsUrlTtlTest do
  @moduledoc """
  Verifies that `:audio_download_url_ttl_seconds` is actually threaded
  into the service's `:expires_in` opt — not merely set on the conn.

  Uses `AshFeedback.Test.DiskFeedback` (Disk service with `:secret`
  configured) because `AshStorage.Service.Test.url/2` ignores
  `:expires_in`, which would let a buggy controller silently pass.
  """

  use ExUnit.Case, async: false
  import Plug.Test

  alias AshFeedback.Controller.AudioDownloadsController

  setup do
    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.DiskFeedback)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:ash_feedback, :audio_download_url_ttl_seconds)
    end)

    :ok
  end

  defp seed_blob! do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.DiskFeedback,
        :audio_clip,
        filename: "x.webm",
        content_type: "audio/webm",
        byte_size: 1
      )

    blob
  end

  defp redirect_url(blob_id) do
    conn =
      conn(:get, "/audio_downloads/#{blob_id}")
      |> Map.put(:path_params, %{"blob_id" => blob_id})
      |> Map.put(:params, %{"blob_id" => blob_id})
      |> AudioDownloadsController.call(AudioDownloadsController.init(:show))

    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    location
  end

  test "URL changes when :audio_download_url_ttl_seconds is overridden" do
    blob = seed_blob!()

    Application.delete_env(:ash_feedback, :audio_download_url_ttl_seconds)
    default_url = redirect_url(blob.id)

    Application.put_env(:ash_feedback, :audio_download_url_ttl_seconds, 60)
    overridden_url = redirect_url(blob.id)

    assert default_url != overridden_url,
           "URLs should differ when TTL changes; got identical URL #{inspect(default_url)} — TTL likely not being threaded into service_opts"
  end
end
