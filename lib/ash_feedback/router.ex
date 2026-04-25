defmodule AshFeedback.Router do
  @moduledoc """
  Router macros that mount ash_feedback's HTTP surface in a host's
  Phoenix router. Mirrors `PhoenixReplay.Router`'s pattern: hosts
  call the macro inside their own scope after `pipe_through`.

      scope "/", MyAppWeb do
        pipe_through :browser
        AshFeedback.Router.audio_routes()
      end

  Optional path prefix:

      AshFeedback.Router.audio_routes(path: "/api/audio")
  """

  defmacro audio_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/audio_uploads")

    quote bind_quoted: [path: path] do
      scope path, alias: false do
        post "/prepare", AshFeedback.Controller.AudioUploadsController, :prepare

        get "/audio_downloads/:blob_id",
            AshFeedback.Controller.AudioDownloadsController,
            :show
      end
    end
  end
end
