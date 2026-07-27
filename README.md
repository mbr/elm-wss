# elm-wss: Simple WebSockets for Elm

`elm-wss` makes browser WebSockets straightforward to use from Elm 0.19. Its small, typed API supports multiple connections, text and JSON messages, and explicit lifecycle and error handling. The JavaScript runtime stays compact, making it easy to vendor and audit.

## Core usage

Once the [ports and JavaScript runtime are configured](https://package.elm-lang.org/packages/mbr/elm-wss/latest/WebsocketSimple), opening a connection and exchanging messages looks like this:

```elm
import WebsocketPorts as Ports
import WebsocketSimple as Ws


type alias Model =
    List String


type Msg
    = WebSocketEvent Ws.RawMsg


init : () -> ( Model, Cmd Msg )
init _ =
    ( [], Ws.open Ports.wsCmd "wss://example.com/socket" )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        WebSocketEvent (Ws.Connected _) ->
            ( model, Ws.send Ports.wsCmd (Ws.Transmit "hello") )

        WebSocketEvent (Ws.Text message) ->
            ( message :: model, Cmd.none )

        WebSocketEvent (Ws.Disconnected _) ->
            ( model, Cmd.none )

        WebSocketEvent (Ws.TransportError error) ->
            ( Ws.errorToString error :: model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.map WebSocketEvent (Ws.subscribe Ports.wsMsg)
```

See the [`WebsocketSimple` package documentation](https://package.elm-lang.org/packages/mbr/elm-wss/latest/WebsocketSimple) for installation, multiple connections, close details, and typed JSON messages.
