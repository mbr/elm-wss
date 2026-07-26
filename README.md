# elm-wss: Simple WebSockets for Elm

This is a simple implementation of websockets for elm, relying on the `port` mechanism available in elm `0.19`. It aims to be readable and easy to understand.

## Installation

Because Elm packages containing `port` modules cannot be published, copy or link these files into your application:

- `elm/WebsocketSimple.elm` into an Elm source directory
- `js/elm-websockets.js` into your browser assets

Using ports also makes the design slightly awkward: Elm does not allow custom `Cmd` implementations, so sending through a port cannot be tied directly to receiving the corresponding event.

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
        WebSocketEvent (Ws.Connected _) ->
            ( model, Ws.send (Ws.Transmit "hello") )

        WebSocketEvent (Ws.Text value) ->
            ( value :: model, Ws.close )

        WebSocketEvent (Ws.Disconnected _) ->
            ( model, Cmd.none )

        WebSocketEvent (Ws.TransportError error) ->
            ( Ws.errorToString error :: model, Cmd.none )


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
        [ Ws.sendWithHandle "chat" (Ws.Open chatUrl [])
        , Ws.sendWithHandle "alerts" (Ws.Open alertsUrl [])
        ]


sendChat : String -> Cmd msg
sendChat message =
    Ws.sendWithHandle "chat" (Ws.Transmit message)


closeChat : Cmd msg
closeChat =
    Ws.sendWithHandle "chat" (Ws.Close Nothing)
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
type alias CloseRequest =
    { code : Int
    , reason : String
    }


type Cmd
    = Open String (List String)
    | Transmit String
    | Close (Maybe CloseRequest)
```

`Open` accepts a URL and an ordered list of requested subprotocols. `Transmit` emits `TransportError` if the socket is not open or the browser rejects the operation. Otherwise it emits no event; WebSocket provides no per-message delivery acknowledgement. `Close Nothing` preserves the browser's default close behavior; `Close (Just request)` sends its code and reason. Use an empty reason to send only a code. `open` and `close` are shortcuts for the default socket.

### Events

```elm
type alias CloseDetails =
    { code : Int
    , reason : String
    , wasClean : Bool
    , initiatedLocally : Bool
    }


type TransportErrorKind
    = ConstructionFailure
    | SendFailure
    | CloseFailure
    | BrowserFailure
    | SendRejection
    | UnsupportedData
    | PortDecodingFailure


type alias TransportErrorDetails =
    { kind : TransportErrorKind
    , message : String
    }


type RawMsg
    = Connected (Maybe String)
    | Disconnected CloseDetails
    | Text String
    | TransportError TransportErrorDetails
```

`Connected` means the socket is ready to transmit and contains the negotiated subprotocol, if any. `Disconnected` includes the browser's close code, reason and `wasClean` flag, plus whether the close was initiated locally; it may occur even if the socket never connected. `Text` contains a text frame. `TransportError` identifies construction, send, close, browser, unsupported-data, and port-decoding failures. Use `errorKindToString` to render its kind alone or `errorToString` to render the kind and readable message.

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

The resulting messages are `Established`, `Closed`, `Received`, `TransportFailure`, or `PayloadDecodeFailure`. `Established` contains the negotiated subprotocol, if any. Payload decoding failures retain the original text and `Json.Decode.Error`. To send JSON, `transmitMsg` applies an encoder and transmits the encoded value. Use `parseIncoming` when decoding a `RawMsg` explicitly.

## Example

Start a local echo server:

```sh
websocat -E --text ws-l:127.0.0.1:8765 mirror:
```

From `example/`, run `./build.sh`, then open `index.html`. Override the endpoint with a query parameter such as `index.html?url=ws://127.0.0.1:9000`.
