module WebsocketSimple.Connection exposing
    ( Config, config, withSchedule, withLimit, withHandle, withProtocols
    , Model, Msg, Event(..), Action(..), Failure(..)
    , init, update, fail, state, get
    , receive, subscribe, perform
    )

{-| Keep a WebSocket connected, retrying when the connection is lost.

Retries use exponential backoff: one second, two seconds, four seconds, up to
one minute between attempts. There is no attempt limit. An established connection
resets the backoff.

Using the application-owned ports described in `WebsocketSimple`, this example
replies to server-sent text with its reverse and counts palindromic inputs:

    import WebsocketPorts as Ports
    import WebsocketSimple as Ws
    import WebsocketSimple.Connection as Connection

    type alias Model =
        { connection : Connection.Model
        , palindromes : Int
        }

    type Msg
        = ConnectionMsg Connection.Msg
        | OtherMessage

    init : () -> ( Model, Cmd Msg )
    init _ =
        let
            ( connection, action ) =
                Connection.init (Connection.config "wss://example.com/messages")
        in
        ( { connection = connection, palindromes = 0 }
        , Connection.perform Ports.wsCmd ConnectionMsg action
        )

    update : Msg -> Model -> ( Model, Cmd Msg )
    update msg model =
        case msg of
            ConnectionMsg connectionMsg ->
                let
                    ( connection, action, incoming ) =
                        Connection.update connectionMsg model.connection

                    updated =
                        { model | connection = connection }

                    ( next, command ) =
                        case incoming of
                            Just event ->
                                handleEvent event updated

                            Nothing ->
                                ( updated, Cmd.none )
                in
                ( next
                , Cmd.batch [ Connection.perform Ports.wsCmd ConnectionMsg action, command ]
                )

            OtherMessage ->
                ( model, Cmd.none )

    handleEvent : Connection.Event -> Model -> ( Model, Cmd Msg )
    handleEvent event model =
        case event of
            Connection.Text body ->
                let
                    reversed =
                        String.reverse body

                    next =
                        if body == reversed then
                            { model | palindromes = model.palindromes + 1 }

                        else
                            model
                in
                ( next
                , case Connection.get model.connection of
                    Just handle ->
                        Ws.sendWithHandle Ports.wsCmd handle (Ws.Transmit reversed)

                    Nothing ->
                        Cmd.none
                )

            _ ->
                ( model, Cmd.none )

    subscriptions : Model -> Sub Msg
    subscriptions _ =
        Connection.subscribe Ports.wsMsg |> Sub.map ConnectionMsg

Receiving `"ABC"` sends back `"CBA"`. Receiving `"ABA"` sends back `"ABA"` and
increments `palindromes`.


# Configuration

@docs Config, config, withSchedule, withLimit, withHandle, withProtocols


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
config : String -> Config
config url =
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


{-| One connection transition's effect, interpreted by `perform`. `Close` carries
an optional retry delay in milliseconds and the message to deliver afterwards.
-}
type Action
    = None
    | Open Ws.Handle String (List String)
    | Close Ws.Handle (Maybe ( Float, Msg ))


{-| The reason a connection was lost or an attempt failed.
-}
type Failure
    = Closed Ws.CloseDetails
    | TransportError Ws.TransportErrorDetails
    | ApplicationError String


{-| Begin the first connection attempt.
-}
init : Config -> ( Model, Action )
init (Config settings) =
    let
        model =
            Model
                { settings = settings
                , remote = Remote.init settings.policy
                , generation = 1
                }
    in
    ( model, open model )


{-| Process a socket event or retry, returning an application event when appropriate.
Events from retired sockets and obsolete retry messages are ignored.

Socket closure, construction failure, and browser transport failure schedule
reconnection without emitting an application event. Other errors are reported as
`Error` without reconnecting.

-}
update : Msg -> Model -> ( Model, Action, Maybe Event )
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
                        ( next, open next, Nothing )

                    else
                        ( original, None, Nothing )

                _ ->
                    ( original, None, Nothing )

        Socket ( handle, event ) ->
            if handle /= currentHandle original || not (active original) then
                ( original, None, Nothing )

            else
                case event of
                    Ws.Connected protocol ->
                        ( Model { model | remote = Remote.succeed handle model.remote }, None, Just (Established protocol) )

                    Ws.Disconnected details ->
                        failed (Closed details) original |> withoutEvent

                    Ws.TransportError error ->
                        case error.kind of
                            Ws.ConstructionFailure ->
                                failed (TransportError error) original |> withoutEvent

                            Ws.BrowserFailure ->
                                failed (TransportError error) original |> withoutEvent

                            _ ->
                                ( original, None, Just (Error error) )

                    Ws.Text body ->
                        ( original, None, Just (Text body) )

                    Ws.Binary body ->
                        ( original, None, Just (Binary body) )


{-| Adapt a lifecycle transition that does not produce an application event.
-}
withoutEvent : ( Model, Action ) -> ( Model, Action, Maybe Event )
withoutEvent ( model, action ) =
    ( model, action, Nothing )


{-| Replace the current connection, for example after a missed application heartbeat.
Repeated failures while waiting to retry or after exhaustion do nothing.
-}
fail : String -> Model -> ( Model, Action )
fail reason =
    failed (ApplicationError reason)


{-| Close a failed attempt and schedule at most one retry for its generation.
-}
failed : Failure -> Model -> ( Model, Action )
failed error ((Model model) as original) =
    if active original then
        let
            ( remote, delay ) =
                Remote.fail error model.remote
        in
        ( Model { model | remote = remote }
        , Close (currentHandle original)
            (Maybe.map (\milliseconds -> ( milliseconds, Retry model.generation )) delay)
        )

    else
        ( original, None )


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
    Open (currentHandle original) model.settings.url model.settings.protocols


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


{-| Execute one connection action through your application.
-}
perform : Ws.CommandPort msg -> (Msg -> msg) -> Action -> Cmd msg
perform commandPort wrap action =
    case action of
        None ->
            Cmd.none

        Open handle url protocols ->
            Ws.sendWithHandle commandPort handle (Ws.Open url protocols)

        Close handle retry ->
            Cmd.batch
                [ Ws.sendWithHandle commandPort handle (Ws.Close Nothing)
                , case retry of
                    Just ( milliseconds, message ) ->
                        RemoteCmd.wakeAfter (wrap message) (Just milliseconds)

                    Nothing ->
                        Cmd.none
                ]
