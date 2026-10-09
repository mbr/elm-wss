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

`WebsocketSimple.Connection` keeps a connection established using [elm-again](https://package.elm-lang.org/packages/mbr/elm-again/latest/). It retries indefinitely with exponential delays from one second up to one minute. Successful connections reset the backoff.

Start with `Connection.config url`, then call `Connection.init`. Feed socket and retry messages through `Connection.update`, and execute the returned actions with `Connection.perform`. `Connection.get` returns the connected handle for sending messages. The [managed example](example/src/Managed.elm) shows the complete wiring.

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

The manager does not implement heartbeats. When your application detects a missing heartbeat, `Connection.fail "Heartbeat missing" model.connection` closes the current socket and schedules a replacement. It neither queues outgoing messages nor replays missed traffic.

Run `./check.sh` in the Nix development shell to check documentation, tests, and both examples.
