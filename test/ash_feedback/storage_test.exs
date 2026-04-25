defmodule AshFeedback.StorageTest do
  @moduledoc """
  Exercises the `PhoenixReplay.Storage` callbacks on `AshFeedback.Storage`
  that have audio-narration semantics — currently `submit/3`'s handling
  of the `params["extras"]` payload introduced by sub-phase 2a.

  Audio-enabled host: `AshFeedback.Test.AudioFeedback` (an ETS-backed
  fixture that mirrors the macro's audio-enabled emission). The Storage
  adapter must read `extras["audio_clip_blob_id"]` and forward it as the
  `:audio_clip_blob_id` argument so `AshStorage.Changes.AttachBlob`
  attaches the blob.

  Audio-disabled host: `AshFeedback.Test.TestFeedback`. The adapter must
  silently drop audio extras rather than raise `NoSuchInput`.
  """
  use AshFeedback.Test.DataCase, async: false

  alias AshFeedback.Storage
  alias AshFeedback.Test.AudioFeedback
  alias AshFeedback.Test.StorageBlob
  alias AshFeedback.Test.StorageDomain
  alias AshFeedback.Test.TestFeedback

  describe "submit/3 — audio-disabled host (TestFeedback)" do
    setup do
      Application.put_env(
        :phoenix_replay,
        :storage,
        {AshFeedback.Storage, resource: TestFeedback, repo: AshFeedback.Test.Repo}
      )

      on_exit(fn -> Application.delete_env(:phoenix_replay, :storage) end)

      :ok
    end

    test "creates a feedback row from minimal params (regression)" do
      assert {:ok, fb} =
               Storage.submit("session-base", %{"description" => "hi"}, %{})

      assert fb.session_id == "session-base"
      assert fb.description == "hi"
    end

    test "extras.audio_clip_blob_id is silently dropped when :submit lacks the argument" do
      blob_id = Ecto.UUID.generate()

      params = %{
        "description" => "no audio here",
        "extras" => %{"audio_clip_blob_id" => blob_id}
      }

      assert {:ok, fb} = Storage.submit("session-drop-audio", params, %{})
      assert fb.description == "no audio here"
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

  describe "submit/3 — audio-enabled host (AudioFeedback)" do
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

    test "submit without extras still works (audio is optional)" do
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
