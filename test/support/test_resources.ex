defmodule AshFeedback.Test.StorageDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshFeedback.Test.StorageBlob
    resource AshFeedback.Test.StorageAttachment
    resource AshFeedback.Test.StorageFeedback
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
