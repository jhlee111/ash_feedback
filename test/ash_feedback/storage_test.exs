defmodule AshFeedback.StorageTest do
  @moduledoc """
  Exercises the `PhoenixReplay.Storage` callbacks on `AshFeedback.Storage`
  that have audio-narration semantics — currently `submit/3`'s handling
  of the `params["extras"]` payload introduced by sub-phase 2a.

  Both fixtures are audio-enabled — audio is core (ADR-0001 Question B
  addendum 2026-04-26), so every host concrete resource accepts
  `:audio_clip_blob_id`. `AshFeedback.Test.TestFeedback` is the
  macro-generated fixture; `AshFeedback.Test.AudioFeedback` is
  hand-rolled with `AshStorage.Service.Test` so the test can drive
  blob attachment end-to-end.
  """
  use AshFeedback.Test.DataCase, async: false

  alias AshFeedback.Storage
  alias AshFeedback.Test.AudioFeedback
  alias AshFeedback.Test.StorageBlob
  alias AshFeedback.Test.StorageDomain
  alias AshFeedback.Test.TestFeedback

  describe "submit/3 — base regressions (TestFeedback)" do
    setup do
      Application.put_env(
        :phoenix_replay,
        :storage,
        {AshFeedback.Storage, resource: TestFeedback, repo: AshFeedback.Test.Repo}
      )

      on_exit(fn -> Application.delete_env(:phoenix_replay, :storage) end)

      :ok
    end

    test "creates a feedback row from minimal params" do
      assert {:ok, fb} =
               Storage.submit("session-base", %{"description" => "hi"}, %{})

      assert fb.session_id == "session-base"
      assert fb.description == "hi"
    end

    test "extras with unrelated keys is a no-op" do
      params = %{
        "description" => "noisy extras",
        "extras" => %{"unrelated" => "value"}
      }

      assert {:ok, fb} = Storage.submit("session-noisy", params, %{})
      assert fb.description == "noisy extras"
    end
  end

  describe "submit/3 — audio attachment (AudioFeedback)" do
    setup do
      AshStorage.Service.Test.start()
      AshStorage.Service.Test.reset!()

      Application.put_env(
        :phoenix_replay,
        :storage,
        {AshFeedback.Storage, resource: AudioFeedback, repo: AshFeedback.Test.Repo}
      )

      on_exit(fn -> Application.delete_env(:phoenix_replay, :storage) end)

      :ok
    end

    test "extras.audio_clip_blob_id is forwarded and attaches the blob" do
      blob = create_blob!()

      params = %{
        "description" => "with audio",
        "extras" => %{"audio_clip_blob_id" => blob.id}
      }

      assert {:ok, fb} = Storage.submit("session-with-audio", params, %{})

      fb = Ash.load!(fb, :audio_clip, domain: StorageDomain)

      assert fb.audio_clip
      assert fb.audio_clip.blob_id == blob.id
    end

    test "submit without extras leaves audio_clip nil" do
      params = %{"description" => "no audio attached"}

      assert {:ok, fb} = Storage.submit("session-audio-host-no-clip", params, %{})

      fb = Ash.load!(fb, :audio_clip, domain: StorageDomain)

      assert fb.description == "no audio attached"
      refute fb.audio_clip
    end
  end

  defp create_blob! do
    StorageBlob
    |> Ash.Changeset.for_create(
      :create,
      %{
        key: "test-key-#{System.unique_integer([:positive])}",
        filename: "voice.webm",
        content_type: "audio/webm",
        byte_size: 1024,
        service_name: AshStorage.Service.Test
      },
      authorize?: false,
      domain: StorageDomain
    )
    |> Ash.create!()
  end
end
