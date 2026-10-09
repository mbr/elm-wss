module WebsocketSimple.Connection exposing
    ( Config, config, withSchedule, withLimit, withHandle, withHandleReuse, withProtocols, withServerTimeout
    , Model, Msg, Event(..), Action(..), Failure(..)
    , init, update, fail, reconnect, state, get
    , receive, subscribe, perform, send, sendBinary
    )

{-| A managed WebSocket connection.

The connection manager keeps a WebSocket connected and reconnects when it closes
or reports a connection failure. By default, it retries immediately, then backs off
exponentially from 250 milliseconds to a maximum delay of one minute. Retries are
unlimited, and establishing a connection resets the backoff.

Each attempt has its own handle by default; see Delayed replies below. The manager
handles connection lifecycle and retries so your application can focus on its
protocol.

Using the application-owned ports described in `WebsocketSimple`, this example
replies to server-sent text with its reverse and counts palindromic inputs:

    import WebsocketPorts as Ports
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
                , Connection.send Ports.wsCmd reversed model.connection
                )

            _ ->
                ( model, Cmd.none )

    subscriptions : Model -> Sub Msg
    subscriptions _ =
        Connection.subscribe Ports.wsMsg |> Sub.map ConnectionMsg

Receiving `"ABC"` sends back `"CBA"`. Receiving `"ABA"` sends back `"ABA"` and
increments `palindromes`.


# Delayed replies

By default, the manager generates a fresh handle for each connection attempt. A
reply command created while handling a received message in `update` stays bound to
that connection: reconnecting cannot redirect it to a replacement socket. This is
not a delivery guarantee; the socket may close before the command executes.

If work continues asynchronously after `update` returns, and its reply must not
cross connections, use one of these approaches:

  - Capture the handle from `get` when starting the work and compare it with `get`
    when the result arrives. Discard the result if the handles no longer match.
  - Handle `Established` by resetting connection-specific protocol state and
    invalidating queued work or outstanding request IDs from the previous connection.

These approaches are useful when your protocol has connection-specific state, such
as an initial snapshot followed by updates. The manager does not reset application
state itself; your application decides what to retain across reconnects.

If replies need not stay on their original connection, simply send using the current
model. `withHandleReuse True` additionally lets already-created commands address a
replacement socket by reusing the same handle across attempts. This only works if
the replacement is open when the command executes. Handle comparisons can no longer
distinguish attempts, though `Established` is still emitted for each successful
connection. Calls to `send` and `sendBinary` while disconnected are still discarded;
there is no buffering or replay.


# Caller-initiated dis- and reconnects

Call `fail` when your application determines that the current connection is unusable:
`Connection.fail "Update sequence gap" model.connection`. This records an
`ApplicationError`, closes the socket, and follows the configured retry schedule
and attempt limit. It only affects an established connection; calls while connecting,
retrying, waiting, or exhausted do nothing. Transport failures during connection
attempts still trigger the normal retry behavior.

Use `reconnect` for a "Reconnect now" button. It replaces an active connection or
skips a pending backoff, starting a fresh attempt immediately. It also works after
exhaustion, resetting the retry count and backoff while retaining your configuration.
Old retry callbacks cannot restart the connection again. Like automatic retries,
it honors `withHandleReuse` and leaves application protocol state to you.

Both functions return a model and an action to pass to `perform`:

    reconnectNow : Model -> ( Model, Cmd Msg )
    reconnectNow model =
        let
            ( connection, action ) =
                Connection.reconnect model.connection
        in
        ( { model | connection = connection }
        , Connection.perform Ports.wsCmd ConnectionMsg action
        )


# Server liveness

Enable an inactivity timeout with `Connection.withServerTimeout 45000`. The clock
starts when the connection opens; every incoming text or binary frame counts as
activity. If the server stays silent for the configured milliseconds, the manager
records `ServerTimeout`, closes the socket, and follows its retry policy. Checks
are disabled by default and do not time out connection attempts.

The server can send periodic heartbeat messages when it has no other data to send.
An empty binary frame works well: the application can discard `Binary` events whose
payload has `Bytes.width` zero. The JSON adapter passes binary frames through too,
so these heartbeats need no JSON representation. Choose a timeout longer than the
heartbeat interval, with room for network and scheduling delays.

WebSocket protocol ping/pong is separate. Browsers automatically answer server
pings, but JavaScript cannot send or observe those control frames. They therefore
do not count as activity here; use application-visible data frames instead.

There is one watchdog timer per established connection. Incoming data updates its
last-activity time without restarting the timer. When it wakes, the manager either
fails the connection or schedules the remaining time until the current deadline.
JSON decoding failures still count as activity; outgoing messages and transport
errors do not.


# Configuration

@docs Config, config, withSchedule, withLimit, withHandle, withHandleReuse, withProtocols, withServerTimeout


# State and transitions

@docs Model, Msg, Event, Action, Failure
@docs init, update, fail, reconnect, state, get


# Integration

@docs receive, subscribe, perform, send, sendBinary

-}

import Again.Policy as Policy exposing (AttemptLimit, Policy)
import Again.Remote as Remote
import Again.Remote.Cmd as RemoteCmd
import Again.Schedule exposing (Schedule(..))
import Bytes exposing (Bytes)
import Process
import Task
import Time exposing (Posix)
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
    , reuseHandle : Bool
    , serverTimeout : Maybe Float
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
        , reuseHandle = False
        , serverTimeout = Nothing
        , policy =
            Policy.unlimited
                (ImmediatelyThen
                    (ExponentialBackoff
                        { initialDelay = 250
                        , multiplier = 2
                        , maxDelay = 60000
                        }
                    )
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
maintaining multiple connections; socket handles are generated within it.
-}
withHandle : Ws.Handle -> Config -> Config
withHandle namespace (Config settings) =
    Config { settings | namespace = namespace }


{-| Reuse one handle across attempts when enabled. The default is `False`.
Delayed sends can then address a replacement socket, and handles no longer
identify individual attempts. Retry messages still belong to distinct attempts.
-}
withHandleReuse : Bool -> Config -> Config
withHandleReuse reuseHandle (Config settings) =
    Config { settings | reuseHandle = reuseHandle }


{-| Request an ordered list of WebSocket subprotocols.
-}
withProtocols : List String -> Config -> Config
withProtocols protocols (Config settings) =
    Config { settings | protocols = protocols }


{-| Reconnect after this many milliseconds without incoming data on an established
connection. Disabled by default. Nonpositive or non-finite values disable checks.
-}
withServerTimeout : Float -> Config -> Config
withServerTimeout milliseconds (Config settings) =
    Config
        { settings
            | serverTimeout =
                if milliseconds > 0 && not (isInfinite milliseconds) then
                    Just milliseconds

                else
                    Nothing
        }


{-| The latest receipt is awaiting its clock reading or has been timestamped.
-}
type Activity
    = Pending Int
    | Observed Posix


{-| Latest activity and the single outstanding watchdog, with distinct callback IDs.
-}
type alias Watchdog =
    { activity : Activity
    , timer : Maybe Int
    , serial : Int
    }


{-| A retrying connection whose successful value is its connected socket handle.
-}
type Model
    = Model
        { settings : Settings
        , remote : Remote.Remote Failure Ws.Handle
        , generation : Int
        , watchdog : Maybe Watchdog
        }


{-| Socket input, clock readings, or a scheduled retry. Route these messages back to `update`.
-}
type Msg
    = Socket ( Ws.Handle, Ws.RawMsg )
    | Retry Int
    | ActivityAt Int Int Posix
    | CheckServer Int Int Posix


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
`Replace` swaps the old handle's socket for a new connection without a retry delay.
`ReadTime` timestamps activity; `CheckAt` waits until a deadline and supplies the
actual wakeup time. Their callbacks return messages for `update`.
-}
type Action
    = None
    | Open Ws.Handle String (List String)
    | Close Ws.Handle (Maybe ( Float, Msg ))
    | Replace Ws.Handle Ws.Handle String (List String)
    | ReadTime (Posix -> Msg)
    | CheckAt Posix (Posix -> Msg)


{-| The reason a connection was lost or an attempt failed.
-}
type Failure
    = Closed Ws.CloseDetails
    | TransportError Ws.TransportErrorDetails
    | ApplicationError String
    | ServerTimeout


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
                , watchdog = Nothing
                }
    in
    ( model, open model )


{-| Process a socket event or retry, returning an application event when appropriate.
Events with unrelated handles and obsolete retry messages are ignored.

Socket closure, construction failure, and browser transport failure schedule
reconnection without emitting an application event. Other errors are reported as
`Error` without reconnecting.

-}
update : Msg -> Model -> ( Model, Action, Maybe Event )
update msg ((Model model) as original) =
    case msg of
        ActivityAt generation receipt now ->
            recordActivity generation receipt now original |> withoutEvent

        CheckServer generation timer now ->
            checkServer generation timer now original |> withoutEvent

        Retry generation ->
            case Remote.state model.remote of
                Remote.WaitingForRetry _ ->
                    if generation == model.generation then
                        let
                            next =
                                Model { model | remote = Remote.beginRetry model.remote, generation = model.generation + 1, watchdog = Nothing }
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
                        observe (Established protocol) (Model { model | remote = Remote.succeed handle model.remote })

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
                        observe (Text body) original

                    Ws.Binary body ->
                        observe (Binary body) original


{-| Mark activity immediately, so an outstanding clock read cannot cause a false timeout.
-}
observe : Event -> Model -> ( Model, Action, Maybe Event )
observe event ((Model model) as original) =
    if model.settings.serverTimeout /= Nothing && get original /= Nothing then
        let
            watchdog =
                Maybe.withDefault { activity = Pending 0, timer = Nothing, serial = 0 } model.watchdog

            receipt =
                watchdog.serial + 1
        in
        ( Model { model | watchdog = Just { watchdog | activity = Pending receipt, serial = receipt } }
        , ReadTime (ActivityAt model.generation receipt)
        , Just event
        )

    else
        ( original, None, Just event )


{-| Retain only the newest receipt's timestamp, starting a timer only when none is pending.
-}
recordActivity : Int -> Int -> Posix -> Model -> ( Model, Action )
recordActivity generation receipt now ((Model model) as original) =
    case ( model.watchdog, model.settings.serverTimeout ) of
        ( Just watchdog, Just timeout ) ->
            if generation == model.generation && watchdog.activity == Pending receipt then
                let
                    next =
                        Model { model | watchdog = Just { watchdog | activity = Observed now } }
                in
                if watchdog.timer == Nothing then
                    scheduleServer (deadline now timeout) next

                else
                    ( next, None )

            else
                ( original, None )

        _ ->
            ( original, None )


{-| Consume the active timer, deferring expiry while a newer receipt awaits its timestamp.
-}
checkServer : Int -> Int -> Posix -> Model -> ( Model, Action )
checkServer generation timer now ((Model model) as original) =
    case ( model.watchdog, model.settings.serverTimeout ) of
        ( Just watchdog, Just timeout ) ->
            if generation == model.generation && watchdog.timer == Just timer then
                let
                    next =
                        Model { model | watchdog = Just { watchdog | timer = Nothing } }
                in
                case watchdog.activity of
                    Pending _ ->
                        ( next, None )

                    Observed lastMessage ->
                        let
                            expires =
                                deadline lastMessage timeout
                        in
                        if Time.posixToMillis now >= Time.posixToMillis expires then
                            failed ServerTimeout next

                        else
                            scheduleServer expires next

            else
                ( original, None )

        _ ->
            ( original, None )


{-| Arm one watchdog with a fresh identity within this connection attempt.
-}
scheduleServer : Posix -> Model -> ( Model, Action )
scheduleServer expires ((Model model) as original) =
    case model.watchdog of
        Just watchdog ->
            let
                timer =
                    watchdog.serial + 1
            in
            ( Model { model | watchdog = Just { watchdog | timer = Just timer, serial = timer } }
            , CheckAt expires (CheckServer model.generation timer)
            )

        Nothing ->
            ( original, None )


{-| Compute an inactivity deadline, rounding fractional milliseconds upwards.
-}
deadline : Posix -> Float -> Posix
deadline lastMessage timeout =
    Time.millisToPosix (Time.posixToMillis lastMessage + ceiling timeout)


{-| Adapt a lifecycle transition that does not produce an application event.
-}
withoutEvent : ( Model, Action ) -> ( Model, Action, Maybe Event )
withoutEvent ( model, action ) =
    ( model, action, Nothing )


{-| Fail an established connection, recording an `ApplicationError` and closing
the socket. Retries follow the configured schedule and attempt limit. Calls in
any other state do nothing; use `reconnect` to replace a pending attempt.
-}
fail : String -> Model -> ( Model, Action )
fail reason model =
    case state model of
        Remote.Successful _ ->
            failed (ApplicationError reason) model

        _ ->
            ( model, None )


{-| Start a fresh attempt immediately, replacing any active connection or skipping
its backoff. Resets the retry count, even after exhaustion, and invalidates pending
retry callbacks. Configuration, including handle reuse, is preserved.
-}
reconnect : Model -> ( Model, Action )
reconnect ((Model model) as original) =
    let
        next =
            Model { model | remote = Remote.init model.settings.policy, generation = model.generation + 1, watchdog = Nothing }
    in
    ( next
    , if active original then
        Replace (currentHandle original) (currentHandle next) model.settings.url model.settings.protocols

      else
        open next
    )


{-| Close a failed attempt and schedule at most one retry for its generation.
-}
failed : Failure -> Model -> ( Model, Action )
failed error ((Model model) as original) =
    if active original then
        let
            ( remote, delay ) =
                Remote.fail error model.remote
        in
        ( Model { model | remote = remote, watchdog = Nothing }
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


{-| Send text through the connected socket. Disconnected sends are discarded,
not buffered or replayed. Delivery is best-effort.
-}
send : Ws.CommandPort msg -> String -> Model -> Cmd msg
send commandPort body =
    transmit commandPort (Ws.Transmit body)


{-| Send binary data with the same best-effort behavior as `send`.
-}
sendBinary : Ws.CommandPort msg -> Bytes -> Model -> Cmd msg
sendBinary commandPort body =
    transmit commandPort (Ws.TransmitBinary body)


{-| Transmit only through an established connection, without retaining data.
-}
transmit : Ws.CommandPort msg -> Ws.Cmd -> Model -> Cmd msg
transmit commandPort command model =
    case get model of
        Just handle ->
            Ws.sendWithHandle commandPort handle command

        Nothing ->
            Cmd.none


{-| Name the socket within its namespace, optionally reusing a reserved generation.
-}
currentHandle : Model -> Ws.Handle
currentHandle (Model model) =
    let
        generation =
            if model.settings.reuseHandle then
                0

            else
                model.generation
    in
    Ws.handle ("elm-wss:" ++ Ws.handleToString model.settings.namespace ++ ":" ++ String.fromInt generation)


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


{-| Execute one connection action through your application. A reused handle is
replaced with a single open command, which closes the old socket in the runtime.
-}
perform : Ws.CommandPort msg -> (Msg -> msg) -> Action -> Cmd msg
perform commandPort wrap action =
    case action of
        None ->
            Cmd.none

        ReadTime callback ->
            Time.now |> Task.perform (callback >> wrap)

        CheckAt expires callback ->
            Time.now
                |> Task.andThen
                    (\now ->
                        Process.sleep
                            (toFloat (Time.posixToMillis expires - Time.posixToMillis now)
                                |> clamp 0 2147483647
                            )
                    )
                |> Task.andThen (\_ -> Time.now)
                |> Task.perform (callback >> wrap)

        Open handle url protocols ->
            Ws.sendWithHandle commandPort handle (Ws.Open url protocols)

        Replace old handle url protocols ->
            Cmd.batch
                [ if old == handle then
                    Cmd.none

                  else
                    Ws.sendWithHandle commandPort old (Ws.Close Nothing)
                , Ws.sendWithHandle commandPort handle (Ws.Open url protocols)
                ]

        Close handle retry ->
            Cmd.batch
                [ Ws.sendWithHandle commandPort handle (Ws.Close Nothing)
                , case retry of
                    Just ( milliseconds, message ) ->
                        RemoteCmd.wakeAfter (wrap message) (Just milliseconds)

                    Nothing ->
                        Cmd.none
                ]
