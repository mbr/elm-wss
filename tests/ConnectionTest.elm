module ConnectionTest exposing (tests)

{-| Exercises connection management without sockets or real sleeping.
-}

import Again.Policy exposing (AttemptLimit(..))
import Again.Remote as Remote
import Again.Schedule exposing (Schedule(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Expect
import Test exposing (Test, describe, test)
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection exposing (Action(..))


{-| Covers indefinite retries, application failures, stale events, and configuration.
-}
tests : Test
tests =
    describe "Managed connections"
        [ test "defaults keep retrying, cap delays at one minute, and reset after connecting" <|
            \_ ->
                let
                    ( initial, actions ) =
                        Connection.init (Connection.new "wss://example.com/socket")
                in
                case failures 10 initial of
                    Ok ( delays, attempting, handle ) ->
                        let
                            ( connected, connectedActions, connectedEvent ) =
                                incoming handle (Ws.Connected (Just "echo.v1")) attempting

                            ( receivedText, textActions, textEvent ) =
                                incoming handle (Ws.Text "hello") connected

                            bytes =
                                Encode.encode (Encode.sequence [ Encode.unsignedInt8 0, Encode.unsignedInt8 255 ])

                            ( receivedBinary, binaryActions, binaryEvent ) =
                                incoming handle (Ws.Binary bytes) receivedText
                        in
                        case incoming handle (Ws.Disconnected closed) receivedBinary of
                            ( waiting, [ Send closing (Ws.Close Nothing), RetryAfter delay _ ], event ) ->
                                Expect.all
                                    [ \_ -> Expect.equal Remote.Attempting (Connection.state initial)
                                    , \_ -> Expect.equal Nothing (Connection.get initial)
                                    , \_ ->
                                        case actions of
                                            [ Send _ (Ws.Open url protocols) ] ->
                                                Expect.equal ( "wss://example.com/socket", [] ) ( url, protocols )

                                            _ ->
                                                Expect.fail "expected one initial open"
                                    , \_ -> Expect.equal [ 1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000, 60000 ] delays
                                    , \_ -> Expect.equal (Just handle) (Connection.get connected)
                                    , \_ -> Expect.equal (Just (Connection.Established (Just "echo.v1"))) connectedEvent
                                    , \_ -> Expect.equal [] connectedActions
                                    , \_ -> Expect.equal (Just (Connection.Text "hello")) textEvent
                                    , \_ -> Expect.equal [] textActions
                                    , \_ ->
                                        case binaryEvent of
                                            Just (Connection.Binary body) ->
                                                Expect.equal (Just ( 0, 255 )) (Decode.decode (Decode.map2 Tuple.pair Decode.unsignedInt8 Decode.unsignedInt8) body)

                                            _ ->
                                                Expect.fail "expected the binary payload to reach the application"
                                    , \_ -> Expect.equal [] binaryActions
                                    , \_ -> Expect.equal handle closing
                                    , \_ -> Expect.equal 1000 delay
                                    , \_ -> Expect.equal Nothing event
                                    , \_ -> Expect.equal (Remote.WaitingForRetry { attempts = 1, lastError = Connection.Closed closed }) (Connection.state waiting)
                                    , \_ -> Expect.equal Nothing (Connection.get waiting)
                                    ]
                                    ()

                            _ ->
                                Expect.fail "expected a closed connection to retry from the initial delay"

                    Err error ->
                        Expect.fail error
        , test "application failure retires the socket and obsolete retries cannot start new attempts" <|
            \_ ->
                case Connection.init (Connection.new "wss://example.com/socket") of
                    ( initial, [ Send first _ ] ) ->
                        let
                            ( connected, _, _ ) =
                                incoming first (Ws.Connected Nothing) initial
                        in
                        case Connection.fail "heartbeat missing" connected of
                            ( waiting, [ Send closing (Ws.Close Nothing), RetryAfter _ retry ] ) ->
                                let
                                    ( duplicate, duplicateActions ) =
                                        Connection.fail "heartbeat still missing" waiting

                                    ( disconnected, closeActions, closeEvent ) =
                                        incoming first (Ws.Disconnected closed) duplicate
                                in
                                case Connection.update retry disconnected of
                                    ( attempting, [ Send second (Ws.Open _ _) ], _ ) ->
                                        let
                                            ( staleSocket, staleActions, staleEvent ) =
                                                incoming first (Ws.Text "late message") attempting
                                        in
                                        case Connection.fail "could not connect" staleSocket of
                                            ( waitingAgain, [ Send _ (Ws.Close Nothing), RetryAfter delay nextRetry ] ) ->
                                                let
                                                    ( staleTimer, timerActions, _ ) =
                                                        Connection.update retry waitingAgain
                                                in
                                                case Connection.update nextRetry staleTimer of
                                                    ( next, [ Send third (Ws.Open _ _) ], _ ) ->
                                                        let
                                                            ( unchanged, secondWakeActions, _ ) =
                                                                Connection.update nextRetry next
                                                        in
                                                        Expect.all
                                                            [ \_ -> Expect.equal first closing
                                                            , \_ -> Expect.equal (Remote.WaitingForRetry { attempts = 1, lastError = Connection.ApplicationError "heartbeat missing" }) (Connection.state waiting)
                                                            , \_ -> Expect.equal [] duplicateActions
                                                            , \_ -> Expect.equal [] closeActions
                                                            , \_ -> Expect.equal Nothing closeEvent
                                                            , \_ -> Expect.notEqual first second
                                                            , \_ -> Expect.equal [] staleActions
                                                            , \_ -> Expect.equal Nothing staleEvent
                                                            , \_ -> Expect.equal 2000 delay
                                                            , \_ -> Expect.equal [] timerActions
                                                            , \_ -> Expect.equal (Connection.state waitingAgain) (Connection.state staleTimer)
                                                            , \_ -> Expect.notEqual second third
                                                            , \_ -> Expect.equal [] secondWakeActions
                                                            , \_ -> Expect.equal (Connection.state next) (Connection.state unchanged)
                                                            ]
                                                            ()

                                                    _ ->
                                                        Expect.fail "expected the current retry to open the third socket"

                                            _ ->
                                                Expect.fail "expected the second failure to schedule one retry"

                                    _ ->
                                        Expect.fail "expected one replacement socket"

                            _ ->
                                Expect.fail "expected application failure to close and schedule a retry"

                    _ ->
                        Expect.fail "expected an initial socket"
        , test "custom schedules, limits, namespaces, and subprotocols apply to every attempt" <|
            \_ ->
                let
                    settings =
                        Connection.new "wss://example.com/chat"
                            |> Connection.withSchedule (Periodic { delay = 7 })
                            |> Connection.withLimit (MaxAttempts 2)
                            |> Connection.withProtocols [ "chat.v1" ]
                            |> Connection.withHandle (Ws.handle "chat")

                    error =
                        { kind = Ws.ConstructionFailure, message = "unavailable" }
                in
                case ( Connection.init settings, Connection.init (Connection.withHandle (Ws.handle "other") settings) ) of
                    ( ( initial, [ Send first (Ws.Open url protocols) ] ), ( _, [ Send other _ ] ) ) ->
                        case incoming first (Ws.TransportError error) initial of
                            ( waiting, [ Send _ _, RetryAfter delay retry ], _ ) ->
                                case Connection.update retry waiting of
                                    ( attempting, [ Send second (Ws.Open retryUrl retryProtocols) ], _ ) ->
                                        let
                                            ( exhausted, actions, event ) =
                                                incoming second (Ws.TransportError error) attempting

                                            ( unchanged, lateActions, _ ) =
                                                Connection.update retry exhausted

                                            ( _, failedActions ) =
                                                Connection.fail "again" unchanged
                                        in
                                        Expect.all
                                            [ \_ -> Expect.equal ( "wss://example.com/chat", [ "chat.v1" ] ) ( url, protocols )
                                            , \_ -> Expect.equal ( url, protocols ) ( retryUrl, retryProtocols )
                                            , \_ -> Expect.notEqual first other
                                            , \_ -> Expect.notEqual first second
                                            , \_ -> Expect.equal 7 delay
                                            , \_ -> Expect.equal [ Send second (Ws.Close Nothing) ] actions
                                            , \_ -> Expect.equal Nothing event
                                            , \_ -> Expect.equal (Remote.Failed (Connection.TransportError error)) (Connection.state exhausted)
                                            , \_ -> Expect.equal Nothing (Connection.get exhausted)
                                            , \_ -> Expect.equal [] lateActions
                                            , \_ -> Expect.equal [] failedActions
                                            ]
                                            ()

                                    _ ->
                                        Expect.fail "expected a second attempt"

                            _ ->
                                Expect.fail "expected a construction failure to retry"

                    _ ->
                        Expect.fail "expected two independently named sockets"
        , test "browser failures reconnect but other transport errors remain application events" <|
            \_ ->
                case Connection.init (Connection.new "wss://example.com/socket") of
                    ( initial, [ Send handle _ ] ) ->
                        let
                            ( connected, _, _ ) =
                                incoming handle (Ws.Connected Nothing) initial

                            check kind =
                                let
                                    error =
                                        { kind = kind, message = "test" }

                                    ( next, actions, event ) =
                                        incoming handle (Ws.TransportError error) connected
                                in
                                Expect.equal ( Just handle, [], Just (Connection.Error error) ) ( Connection.get next, actions, event )
                        in
                        Expect.all
                            [ \_ ->
                                Expect.all (List.map (\kind _ -> check kind) [ Ws.SendFailure, Ws.CloseFailure, Ws.SendRejection, Ws.UnsupportedData, Ws.PortDecodingFailure ]) ()
                            , \_ ->
                                case incoming handle (Ws.TransportError { kind = Ws.BrowserFailure, message = "lost" }) connected of
                                    ( waiting, [ Send _ (Ws.Close Nothing), RetryAfter _ _ ], event ) ->
                                        Expect.equal ( Nothing, Nothing ) ( Connection.get waiting, event )

                                    _ ->
                                        Expect.fail "expected a browser failure to reconnect"
                            ]
                            ()

                    _ ->
                        Expect.fail "expected an initial socket"
        ]


{-| A peer-initiated normal close still requires reconnecting.
-}
closed : Ws.CloseDetails
closed =
    { code = 1000, reason = "", wasClean = True, initiatedLocally = False }


{-| Forward a socket event through the public adapter.
-}
incoming : Ws.Handle -> Ws.RawMsg -> Connection.Model -> ( Connection.Model, List Action, Maybe Connection.Event )
incoming handle event =
    Connection.update (Connection.receive ( handle, event ))


{-| Drive successive failed attempts and collect their scheduled delays.
-}
failures : Int -> Connection.Model -> Result String ( List Float, Connection.Model, Ws.Handle )
failures remaining model =
    case Connection.fail "unavailable" model of
        ( waiting, [ Send old (Ws.Close Nothing), RetryAfter delay retry ] ) ->
            case Connection.update retry waiting of
                ( next, [ Send handle (Ws.Open _ _) ], Nothing ) ->
                    if old == handle then
                        Err "a retry reused the previous attempt's handle"

                    else if remaining == 1 then
                        Ok ( [ delay ], next, handle )

                    else
                        failures (remaining - 1) next
                            |> Result.map (\( delays, final, last ) -> ( delay :: delays, final, last ))

                _ ->
                    Err "expected each retry message to open exactly one socket"

        _ ->
            Err "expected each failure to close the socket and schedule one retry"
