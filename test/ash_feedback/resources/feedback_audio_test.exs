defmodule AshFeedback.Resources.FeedbackAudioTest do
  @moduledoc """
  Verifies that `AshFeedback.Resources.Feedback`'s `__using__/1` macro
  emits the audio narration wiring (storage section + `:submit` action's
  `:audio_clip_blob_id` argument + `AshStorage.Changes.AttachBlob`
  change) for every host concrete resource.

  Audio narration is core (ADR-0001 Question B addendum 2026-04-26):
  the macro never gates the audio block; hosts must always provide
  `:audio_blob_resource` and `:audio_attachment_resource` opts.
  """
  use ExUnit.Case, async: false

  @fixture_module AshFeedback.Resources.FeedbackAudioTest.Fixture

  setup do
    on_exit(fn ->
      :code.purge(@fixture_module)
      :code.delete(@fixture_module)
    end)

    :ok
  end

  test "compiles and emits the full audio wiring" do
    Code.compile_string("""
    defmodule #{inspect(@fixture_module)} do
      @moduledoc false
      use AshFeedback.Resources.Feedback,
        domain: AshFeedback.Test.Feedback,
        repo: AshFeedback.Test.Repo,
        assignee_resource: AshFeedback.Test.User,
        audio_blob_resource: AshFeedback.Test.StorageBlob,
        audio_attachment_resource: AshFeedback.Test.StorageAttachment
    end
    """)

    # 1. The :submit action gains the blob-id argument.
    action = Ash.Resource.Info.action(@fixture_module, :submit)
    arg_names = Enum.map(action.arguments, & &1.name)

    assert :audio_clip_blob_id in arg_names

    # Single-clip-per-session model: no offset argument exists.
    refute :audio_start_offset_ms in arg_names

    blob_arg = Enum.find(action.arguments, &(&1.name == :audio_clip_blob_id))
    assert blob_arg.type == Ash.Type.UUID
    assert blob_arg.allow_nil? == true

    # 2. The :submit action declares the AttachBlob change.
    attach_blob =
      Enum.find(action.changes, fn change ->
        match?({AshStorage.Changes.AttachBlob, _}, change.change)
      end)

    assert attach_blob, ":submit must include AshStorage.Changes.AttachBlob"

    {AshStorage.Changes.AttachBlob, opts} = attach_blob.change
    assert opts[:argument] == :audio_clip_blob_id
    assert opts[:attachment] == :audio_clip

    # 3. The :audio_clip attachment is registered on the resource.
    attachments = AshStorage.Info.attachments(@fixture_module)
    audio_clip = Enum.find(attachments, &(&1.name == :audio_clip))

    assert audio_clip
    assert audio_clip.type == :one
    assert audio_clip.dependent == :purge
  end

  test "raises a helpful error when audio resources are missing" do
    assert_raise ArgumentError, ~r/:audio_blob_resource/, fn ->
      Code.compile_string("""
      defmodule AshFeedback.Resources.FeedbackAudioTest.MissingResources do
        @moduledoc false
        use AshFeedback.Resources.Feedback,
          domain: AshFeedback.Test.Feedback,
          repo: AshFeedback.Test.Repo,
          assignee_resource: AshFeedback.Test.User
      end
      """)
    end
  end
end
