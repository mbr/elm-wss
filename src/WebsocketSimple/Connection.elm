module WebsocketSimple.Connection exposing
    ( Config, new, withSchedule, withLimit, withHandle, withProtocols
    , Model, Msg, Event(..), Action(..), Failure(..)
    , init, update, fail, state, get
    , receive, subscribe, perform
    )

{-| Keep a WebSocket connected, retrying when the connection is lost.

    import WebsocketSimple.Connection as Connection

    config =
        Connection.new "wss://example.com/socket"

Retries use exponential backoff: one second, two seconds, four seconds, up to
one minute between attempts. There is no attempt limit. An established connection
resets the backoff.

`init`, `update`, and `fail` return actions without performing I/O. Execute them
with `Connection.perform Ports.wsCmd ConnectionMsg actions`, and feed the resulting
messages back to `update`.

Subscribe with `Connection.subscribe Ports.wsMsg |> Sub.map ConnectionMsg`.
`update` returns application events for established connections, received data,
and errors that do not trigger reconnection. See the [managed example](https://github.com/mbr/elm-wss/blob/main/example/src/Managed.elm)
for a complete model and update function.

Use `get` to obtain a connected handle for sending through `WebsocketSimple`.
Application protocols own their heartbeats; call `fail` when the current
connection needs replacing.


# Configuration

@docs Config, new, withSchedule, withLimit, withHandle, withProtocols


# State and transitions

@docs Model, Msg, Event, Action, Failure
@docs init, update, fail, state, get


# Integration

@docs receive, subscribe, perform

-}

import Again.Policy as Policy exposing (AttemptLimit, Policy)
import Again.Remote as Remote
import Again.Remote.Cmd as RemoteCmd
import Again.Schedule exposing (Schedule(..))
import Bytes exposing (Bytes)
import WebsocketSimple as Ws


{-| Connection settings, applied before the first attempt.
-}
type Config
    = Config Settings


{-| Transport details and the retry policy used by a manager.
-}
type alias Settings =
    { url : String
    , protocols : List String
    , namespace : Ws.Handle
    , policy : Policy
    }


{-| Configure an indefinitely maintained connection with capped exponential backoff.
-}
new : String -> Config
new url =
    Config
        { url = url
        , protocols = []
        , namespace = Ws.handle "default"
        , policy =
            Policy.unlimited
                (ExponentialBackoff
                    { initialDelay = 1000
                    , multiplier = 2
                    , maxDelay = 60000
                    }
                )
        }


{-| Choose the delay between retries.
-}
withSchedule : Schedule -> Config -> Config
withSchedule schedule (Config settings) =
    let
        policy =
            settings.policy
    in
    Config { settings | policy = { policy | schedule = schedule } }


{-| Limit attempts in a retry sequence, including its initial attempt.
-}
withLimit : AttemptLimit -> Config -> Config
withLimit limit (Config settings) =
    let
        policy =
            settings.policy
    in
    Config { settings | policy = { policy | limit = limit } }


{-| Give the manager its own handle namespace. Use distinct namespaces when
maintaining multiple connections; individual attempt handles are generated within it.
-}
withHandle : Ws.Handle -> Config -> Config
withHandle namespace (Config settings) =
    Config { settings | namespace = namespace }


{-| Request an ordered list of WebSocket subprotocols.
-}
withProtocols : List String -> Config -> Config
withProtocols protocols (Config settings) =
    Config { settings | protocols = protocols }


{-| A retrying connection whose successful value is its connected socket handle.
-}
type Model
    = Model
        { settings : Settings
        , remote : Remote.Remote Failure Ws.Handle
        , generation : Int
        }


{-| Socket input or a scheduled retry. Route these messages back to `update`.
-}
type Msg
    = Socket ( Ws.Handle, Ws.RawMsg )
    | Retry Int


{-| Application events from the managed connection. `Established` includes the
negotiated subprotocol and lets your application initialize each new connection.
`Error` reports errors that do not trigger reconnection; connection loss and
retry failures are available through `state` instead.
-}
type Event
    = Established (Maybe String)
    | Text String
    | Binary Bytes
    | Error Ws.TransportErrorDetails


{-| A transport operation or a delayed retry message, interpreted by `perform`.
-}
type Action
    = Send Ws.Handle Ws.Cmd
    | RetryAfter Float Msg


{-| The reason a connection was lost or an attempt failed.
-}
type Failure
    = Closed Ws.CloseDetails
    | TransportError Ws.TransportErrorDetails
    | ApplicationError String


{-| Begin the first connection attempt.
-}
init : Config -> ( Model, List Action )
init (Config settings) =
    let
        model =
            Model
                { settings = settings
                , remote = Remote.init settings.policy
                , generation = 1
                }
    in
    ( model, [ open model ] )


{-| Process a socket event or retry, returning an application event when appropriate.
Events from retired sockets and obsolete retry messages are ignored.

Socket closure, construction failure, and browser transport failure schedule
reconnection without emitting an application event. Other errors are reported as
`Error` without reconnecting.

-}
update : Msg -> Model -> ( Model, List Action, Maybe Event )
update msg ((Model model) as original) =
    case msg of
        Retry generation ->
            case Remote.state model.remote of
                Remote.WaitingForRetry _ ->
                    if generation == model.generation then
                        let
                            next =
                                Model { model | remote = Remote.beginRetry model.remote, generation = model.generation + 1 }
                        in
                        ( next, [ open next ], Nothing )

                    else
                        ( original, [], Nothing )

                _ ->
                    ( original, [], Nothing )

        Socket ( handle, event ) ->
            if handle /= currentHandle original || not (active original) then
                ( original, [], Nothing )

            else
                case event of
                    Ws.Connected protocol ->
                        ( Model { model | remote = Remote.succeed handle model.remote }, [], Just (Established protocol) )

                    Ws.Disconnected details ->
                        failed (Closed details) original |> withoutEvent

                    Ws.TransportError error ->
                        case error.kind of
                            Ws.ConstructionFailure ->
                                failed (TransportError error) original |> withoutEvent

                            Ws.BrowserFailure ->
                                failed (TransportError error) original |> withoutEvent

                            _ ->
                                ( original, [], Just (Error error) )

                    Ws.Text body ->
                        ( original, [], Just (Text body) )

                    Ws.Binary body ->
                        ( original, [], Just (Binary body) )


{-| Adapt a lifecycle transition that does not produce an application event.
-}
withoutEvent : ( Model, List Action ) -> ( Model, List Action, Maybe Event )
withoutEvent ( model, actions ) =
    ( model, actions, Nothing )


{-| Replace the current connection, for example after a missed application heartbeat.
Repeated failures while waiting to retry or after exhaustion do nothing.
-}
fail : String -> Model -> ( Model, List Action )
fail reason =
    failed (ApplicationError reason)


{-| Close a failed attempt and schedule at most one retry for its generation.
-}
failed : Failure -> Model -> ( Model, List Action )
failed error ((Model model) as original) =
    if active original then
        let
            ( remote, delay ) =
                Remote.fail error model.remote
        in
        ( Model { model | remote = remote }
        , Send (currentHandle original) (Ws.Close Nothing)
            :: (case delay of
                    Just milliseconds ->
                        [ RetryAfter milliseconds (Retry model.generation) ]

                    Nothing ->
                        []
               )
        )

    else
        ( original, [] )


{-| Whether this generation is still attempting or maintaining a connection.
-}
active : Model -> Bool
active model =
    case state model of
        Remote.Attempting ->
            True

        Remote.Retrying _ ->
            True

        Remote.Successful _ ->
            True

        _ ->
            False


{-| Inspect connection progress and the latest failure through `Again.Remote`.
-}
state : Model -> Remote.State Failure Ws.Handle
state (Model model) =
    Remote.state model.remote


{-| Get the connected socket handle, or `Nothing` while disconnected.
-}
get : Model -> Maybe Ws.Handle
get (Model model) =
    Remote.get model.remote


{-| Name the current attempt independently of its retry count.
-}
currentHandle : Model -> Ws.Handle
currentHandle (Model model) =
    Ws.handle ("elm-wss:" ++ Ws.handleToString model.settings.namespace ++ ":" ++ String.fromInt model.generation)


{-| Describe the transport operation for the current attempt.
-}
open : Model -> Action
open ((Model model) as original) =
    Send (currentHandle original) (Ws.Open model.settings.url model.settings.protocols)


{-| Forward an event from an existing handled WebSocket subscription.
-}
receive : ( Ws.Handle, Ws.RawMsg ) -> Msg
receive =
    Socket


{-| Subscribe to socket events through an application-owned event port.
-}
subscribe : Ws.EventPort ( Ws.Handle, Ws.RawMsg ) -> Sub Msg
subscribe eventPort =
    Ws.subscribeWithHandle eventPort |> Sub.map receive


{-| Execute transport operations and schedule retry messages through your application.
-}
perform : Ws.CommandPort msg -> (Msg -> msg) -> List Action -> Cmd msg
perform commandPort wrap actions =
    actions
        |> List.map
            (\action ->
                case action of
                    Send handle command ->
                        Ws.sendWithHandle commandPort handle command

                    RetryAfter milliseconds retry ->
                        RemoteCmd.wakeAfter (wrap retry) (Just milliseconds)
            )
        |> Cmd.batch
