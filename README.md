# elm-wss: Simple websockets for elm

This is a simple implementation of websockets for elm, relying on the `port` mechanism available in elm `0.19`[^1]. It aims to be readable and easy to understand.

# Usage

There is no integration with elm-packages, the easiest way to use this package is to either copy the two files into your source dir or link them using a git submodule:

`elm-websockets.js` should be sourced by your `index.html`, either or after loading the elm source. Once the elm app has been loaded, call `ElmSockets.init_app(app)` on your elm application `app` to initialize the ports. Example:

```html
<script src="elm-websockets.js"></script>
<script src="app.js"></script>
<script>
var app = Elm.Main.init({
  node: document.getElementById('elm')
});
ElmWebsockets.initApp(app);
</script>
```

(`app.js` is your compiled Elm-Apps source). You can pass a second parameter of `true` to `initApp` to enable debug console output.

`WebsocketSimple.elm` is a single port module that handles sending and receiving websocket messages via ports. Calling `WebsocketSimple.send` sends commands to the websockets handler outside of elm.

```elm
import WebsocketSimple as Ws


{|- Example message type for the app -}
type Message =
    WebsocketReceived Ws.Msg

{|- This example show how to open a websocket -}
openWebsocket : Cmd msg
openWebsocket url = Ws.send (Ws.Open url Nothing)


{|- How to subscribe to incoming messages -}
subscriptions : Model -> Sub Message
subscriptions _ =
    Sub.map WebsocketReceived <| Ws.subscribe
```

Each websocket namespaced by a handle (a `String`), somewhat similar to a file socket in systems programming. Handles are created by the elm application, but are optional. If desired, use `sendWithHandle` and `subscribeWithHandle` instead of their basic counterparts `send` and `subscribe`.

# Example

An small [example](example/) application is available.

[^1]: As of 0.19, Elm does not longer ship with built-in websockets.
