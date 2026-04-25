defmodule AshFeedback.RouterTest do
  use ExUnit.Case

  defmodule TestRouter do
    use Phoenix.Router
    require AshFeedback.Router
    AshFeedback.Router.audio_routes()
  end

  test "audio_routes/0 mounts POST /audio_uploads/prepare" do
    routes = TestRouter.__routes__()
    route = Enum.find(routes, fn r -> r.path == "/audio_uploads/prepare" end)

    assert route
    assert route.verb == :post
    assert route.plug == AshFeedback.Controller.AudioUploadsController
    assert route.plug_opts == :prepare
  end

  defmodule TestRouterCustomPath do
    use Phoenix.Router
    require AshFeedback.Router
    AshFeedback.Router.audio_routes(path: "/api/audio")
  end

  test "audio_routes(path: ...) supports a custom mount path" do
    routes = TestRouterCustomPath.__routes__()
    route = Enum.find(routes, fn r -> r.path == "/api/audio/prepare" end)

    assert route
    assert route.verb == :post
  end
end
