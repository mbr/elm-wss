# elm-wss: Simple WebSockets for Elm

`elm-wss` makes browser WebSockets straightforward to use from Elm 0.19. Its small, typed API supports multiple connections, text, binary, and JSON messages, and explicit lifecycle and error handling. The JavaScript runtime stays compact, making it easy to vendor and audit.

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

        WebSocketEvent (Ws.Binary _) ->
            ( model, Cmd.none )

        WebSocketEvent (Ws.Disconnected _) ->
            ( model, Cmd.none )

        WebSocketEvent (Ws.TransportError error) ->
            ( Ws.errorToString error :: model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.map WebSocketEvent (Ws.subscribe Ports.wsMsg)
```

See the [`WebsocketSimple` package documentation](https://package.elm-lang.org/packages/mbr/elm-wss/latest/WebsocketSimple) for installation, multiple connections, close details, and typed JSON messages.

## Maintained connections

`WebsocketSimple.Connection` keeps a connection established using [elm-again](https://package.elm-lang.org/packages/mbr/elm-again/latest/). It retries immediately, then indefinitely with exponential delays from 250 milliseconds up to one minute. Successful connections reset the backoff.

Start with `Connection.config url`, then call `Connection.init`. Feed socket and retry messages through `Connection.update`, and execute the returned action with `Connection.perform`. Send messages with `Connection.send` or `Connection.sendBinary`; disconnected sends are discarded, without buffering or replay. The [managed example](example/src/Managed.elm) shows the complete wiring.

Application events are `Established` (with the negotiated subprotocol), `Text`, `Binary`, and `Error` for errors that do not trigger retries. The manager handles disconnects and retry failures internally; inspect them through `Connection.state`.

To customize retries:

```elm
import Again.Policy exposing (AttemptLimit(..))
import Again.Schedule exposing (Schedule(..))
import WebsocketSimple.Connection as Connection

config =
    Connection.config "wss://example.com/socket"
        |> Connection.withSchedule (Periodic { delay = 5000 })
        |> Connection.withLimit (MaxAttempts 10)
```

Enable `Connection.withServerTimeout 45000` to reconnect after 45 seconds without incoming text or binary data on an established connection. Checks are disabled by default. A server can send empty binary frames as heartbeats; applications can discard them, including through the JSON adapter. Leave room between the heartbeat interval and timeout for network and scheduling delays. Browser-managed protocol ping/pong is not visible to Elm and does not reset this timeout.

Use `Connection.fail "Update sequence gap" model.connection` when your application determines that an established connection is unusable. It closes the socket and follows the retry policy. No outgoing messages are buffered or replayed.

For JSON protocols, use `WebsocketSimple.Connection.Json.update` with your decoder and `Json.send` with your encoder. It uses the same connection model and actions. Incoming text becomes `Received value` or `PayloadDecodeFailure text error`; binary frames pass through unchanged. Decode failures do not disconnect automatically; the application can call `Connection.fail` if needed.

Run `./check.sh` in the Nix development shell to check documentation, tests, and both examples.
