# elm-wss: Simple WebSockets for Elm

A small Elm 0.19 wrapper around the browser `WebSocket` API. It consists of an
Elm port module and a readable JavaScript runtime.

## Installation

Because Elm packages containing `port` modules cannot be published, copy or
link these files into your application:

- `elm/WebsocketSimple.elm` into an Elm source directory
- `js/elm-websockets.js` into your browser assets

Load the runtime and your compiled Elm application, initialize Elm, then
initialize the runtime:

```html
<script src="elm-websockets.js"></script>
<script src="app.js"></script>
<script>
var app = Elm.Main.init({
  node: document.getElementById("elm")
});
ElmWebsockets.initApp(app);
</script>
```

Pass `true` as the second argument to `initApp` to log WebSocket activity.

## Usage

Subscribe before opening a socket. Wait for `Connected` before transmitting.

```elm
import WebsocketSimple as Ws


type alias Model =
    List String


type Msg
    = WebSocketEvent Ws.RawMsg


init : () -> ( Model, Cmd Msg )
init _ =
    ( [], Ws.open "ws://127.0.0.1:8765" )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        WebSocketEvent Ws.Connected ->
            ( model, Ws.send (Ws.Transmit "hello") )

        WebSocketEvent (Ws.Text value) ->
            ( value :: model, Ws.close )

        WebSocketEvent Ws.Disconnected ->
            ( model, Cmd.none )

        WebSocketEvent (Ws.RawError error) ->
            ( error :: model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.map WebSocketEvent Ws.subscribe
```

### Commands

- `Open url protocol` opens a socket with an optional subprotocol.
- `Transmit text` sends a text frame.
- `Close code reason` closes it with an optional code and reason.

`open` and `close` are shortcuts for the default socket.

### Events

- `Connected` means the socket is ready to transmit.
- `Disconnected` means it closed.
- `Text value` contains a text frame.
- `RawError message` reports a runtime or port error.

### Handles

The convenience functions use the handle `"default"`. Use `sendWithHandle` and
`subscribeWithHandle` for multiple sockets; incoming values then include the
handle that produced them.

### JSON

`transmitMsg` JSON-encodes a value before sending it. `subscribeMsg` applies a
JSON decoder and returns `Established`, `Closed`, `Received value`, or
`Error message`. Use `parseIncoming` when decoding a `RawMsg` explicitly.

## Limitations

- Only text frames are supported.
- Sending is valid only after `Connected` and before `Disconnected`.
- A socket cannot be closed through this wrapper while it is still connecting.
- Reconnection, replay, authentication, and application protocols belong to the
  application.
- Browser security rules still apply; in particular, HTTPS pages normally need
  `wss` endpoints.
- Call `ElmWebsockets.initApp` once for each Elm application.

## Example

Start a local echo server:

```sh
websocat -E --text ws-l:127.0.0.1:8765 mirror:
```

From `example/`, run `./build.sh`, then open `index.html`.
