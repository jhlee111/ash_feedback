defmodule AshFeedback.Domain do
  @moduledoc """
  Placeholder reference for the typical `Ash.Domain` shape a host
  builds when consuming `ash_feedback`. Because `Ash.Domain` requires
  its member resources to be concrete modules — and the concrete
  resource lives in the host (see `AshFeedback.Resources.Feedback`
  for why) — this module doesn't define a runtime domain itself.

  ## Example host domain

      defmodule MyApp.Feedback do
        use Ash.Domain, otp_app: :my_app

        resources do
          resource MyApp.Feedback.Entry
        end
      end

      defmodule MyApp.Feedback.Entry do
        use AshFeedback.Resources.Feedback,
          domain: MyApp.Feedback,
          repo: MyApp.Repo
      end

  The host's `MyApp.Feedback.Entry` module then appears in the
  `AshFeedback.Storage` configuration:

      config :phoenix_replay,
        storage: {AshFeedback.Storage,
          resource: MyApp.Feedback.Entry,
          repo: MyApp.Repo}
  """
end
