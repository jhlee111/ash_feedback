defmodule AshFeedback.Test.StorageDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshFeedback.Test.StorageBlob
    resource AshFeedback.Test.StorageAttachment
    resource AshFeedback.Test.StorageFeedback
    resource AshFeedback.Test.AudioFeedback
  end
end

defmodule AshFeedback.Test.StorageBlob do
  @moduledoc false
  use Ash.Resource,
    domain: AshFeedback.Test.StorageDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.BlobResource]

  blob do
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshFeedback.Test.StorageAttachment do
  @moduledoc false
  use Ash.Resource,
    domain: AshFeedback.Test.StorageDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.AttachmentResource]

  attachment do
    blob_resource AshFeedback.Test.StorageBlob
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshFeedback.Test.AudioFeedback do
  @moduledoc """
  Audio-enabled feedback fixture. Mirrors the shape that
  `AshFeedback.Resources.Feedback`'s `__using__/1` macro would emit when
  `audio_enabled` is true at compile time, hand-rolled to keep the test
  fixture independent of the macro's runtime-config gymnastics.

  Used by `AshFeedback.StorageTest` to verify that `submit/3` forwards
  `params["extras"]["audio_clip_blob_id"]` to the action's
  `:audio_clip_blob_id` argument and the `AttachBlob` change wires it.
  """
  use Ash.Resource,
    domain: AshFeedback.Test.StorageDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  storage do
    blob_resource AshFeedback.Test.StorageBlob
    attachment_resource AshFeedback.Test.StorageAttachment

    has_one_attached :audio_clip,
      service: {AshStorage.Service.Test, []}
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string do
      public? true
      allow_nil? false
    end

    attribute :description, :string, public?: true
    attribute :severity, :atom, public?: true
    attribute :metadata, :map, public?: true, default: %{}
    attribute :identity, :map, public?: true, default: %{}
    attribute :events_s3_key, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :submit do
      accept [:session_id, :description, :severity, :metadata, :identity, :events_s3_key]

      argument :audio_clip_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob,
              argument: :audio_clip_blob_id, attachment: :audio_clip}
    end
  end
end

defmodule AshFeedback.Test.StorageFeedback do
  @moduledoc false
  use Ash.Resource,
    domain: AshFeedback.Test.StorageDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  storage do
    blob_resource AshFeedback.Test.StorageBlob
    attachment_resource AshFeedback.Test.StorageAttachment

    has_one_attached :audio_clip,
      service: {AshStorage.Service.Test, []}
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy, create: :*]
  end
end
