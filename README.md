# elm-wss: Simple WebSockets for Elm

This is a simple implementation of websockets for elm, relying on the `port` mechanism available in elm `0.19`. It aims to be readable and easy to understand.

## Installation

Because Elm packages containing `port` modules cannot be published, copy or link these files into your application:

- `elm/WebsocketSimple.elm` into an Elm source directory
- `js/elm-websockets.js` into your browser assets

Load the runtime and your compiled Elm application, initialize Elm, then initialize the runtime:

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

Pass `true` as the second argument to `initApp` to log WebSocket activity using `console.log`.

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

## Multiple connections

Each connection is identified by a string handle. Use the same handle to open, transmit through, and close a connection:

```elm
openConnections : Cmd msg
openConnections =
    Cmd.batch
        [ Ws.sendWithHandle "chat" (Ws.Open chatUrl Nothing)
        , Ws.sendWithHandle "alerts" (Ws.Open alertsUrl Nothing)
        ]


sendChat : String -> Cmd msg
sendChat message =
    Ws.sendWithHandle "chat" (Ws.Transmit message)


closeChat : Cmd msg
closeChat =
    Ws.sendWithHandle "chat" (Ws.Close Nothing Nothing)
```

Use `subscribeWithHandle` to receive the originating handle with each event:

```elm
type Msg
    = WebSocketEvent ( String, Ws.RawMsg )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.map WebSocketEvent Ws.subscribeWithHandle
```

`send` and `subscribe` use the implicit `"default"` handle. `subscribe` discards handle information.

## Reference

### Commands

```elm
type Cmd
    = Open String (Maybe String)
    | Transmit String
    | Close (Maybe Int) (Maybe String)
```

`Open` accepts a URL and optional subprotocol. `Transmit` emits `RawError` when the socket is not open. `Close` accepts an optional code and reason. `open` and `close` are shortcuts for the default socket.

### Events

```elm
type RawMsg
    = Connected
    | Disconnected
    | Text String
    | RawError String
```

`Connected` means the socket is ready to transmit. `Disconnected` means the current connection attempt closed, even if it never connected. `Text` contains a text frame. `RawError` reports a runtime or port error.

### JSON

Regular subscriptions expose incoming text frames as `Text String`. For JSON messages, use `subscribeMsg` with a decoder instead:

```elm
import Json.Decode as Decode


type alias Payload =
    { message : String }


payloadDecoder : Decode.Decoder Payload
payloadDecoder =
    Decode.map Payload (Decode.field "message" Decode.string)


type Msg
    = WebSocketMessage (Ws.Msg Payload)


subscriptions : Model -> Sub Msg
subscriptions _ =
    Ws.subscribeMsg payloadDecoder WebSocketMessage
```

The resulting messages are `Established`, `Closed`, `Received payload`, or `Error message`. To send JSON, `transmitMsg` applies an encoder and transmits the encoded value. Use `parseIncoming` when decoding a `RawMsg` explicitly.

## Limitations

- Only text frames are supported.
- Reconnection, replay, authentication, and application protocols belong to the application.
- Browser security rules still apply; in particular, HTTPS pages normally need `wss` endpoints.
- Call `ElmWebsockets.initApp` once for each Elm application.

## Example

Start a local echo server:

```sh
websocat -E --text ws-l:127.0.0.1:8765 mirror:
```

From `example/`, run `./build.sh`, then open `index.html`.
