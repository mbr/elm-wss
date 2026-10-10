module ConnectionTimeoutTest exposing (tests)

{-| Drives the inactivity watchdog with native timestamps and logical timer messages.
-}

import Again.Policy exposing (AttemptLimit(..))
import Again.Remote as Remote
import Bytes
import Bytes.Encode as BytesEncode
import Expect
import Json.Decode as Decode
import SocketEvent
import Test exposing (Test, describe, test)
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection exposing (Action(..))
import WebsocketSimple.Connection.Json as Json


{-| A short timeout keeps deadline arithmetic readable.
-}
config : Connection.Config
config =
    Connection.config "wss://example.com/socket" |> Connection.withServerTimeout 100


{-| A fractional, nonzero connection epoch detects accidental clock-domain mixing.
-}
epoch : Float
epoch =
    1000000.25


{-| Checks lazy rescheduling, delayed events, retired attempts, and disabled checks.
-}
tests : Test
tests =
    describe "Server inactivity timeout"
        ([ test "binary heartbeats and malformed JSON advance fractional activity without restarting the timer" <|
            \_ ->
                watching config <|
                    \model handle firstDelay firstWake ->
                        let
                            empty =
                                BytesEncode.encode (BytesEncode.sequence [])
                        in
                        case Json.update Decode.int (SocketEvent.at (epoch + 75.5) handle (Ws.Binary empty)) model of
                            ( received, None, Just (Json.Binary bytes) ) ->
                                let
                                    ( afterOldFrame, oldFrameAction, _ ) =
                                        Connection.update (SocketEvent.at (epoch + 25) handle (Ws.Text "delayed")) received

                                    ( afterError, errorAction, _ ) =
                                        Connection.update
                                            (SocketEvent.at (epoch + 90) handle (Ws.TransportError { kind = Ws.UnsupportedData, message = "unsupported" }))
                                            afterOldFrame
                                in
                                case Connection.update firstWake afterError of
                                    ( extended, CheckAfter secondDelay secondWake, Nothing ) ->
                                        case Json.update Decode.int (SocketEvent.at (epoch + 120.75) handle (Ws.Text "not JSON")) extended of
                                            ( textReceived, None, Just (Json.PayloadDecodeFailure _ _) ) ->
                                                let
                                                    ( unchanged, staleAction, _ ) =
                                                        Connection.update firstWake textReceived
                                                in
                                                case Connection.update secondWake unchanged of
                                                    ( final, CheckAfter lastDelay lastWake, Nothing ) ->
                                                        Expect.all
                                                            [ \_ -> Expect.equal 100 firstDelay
                                                            , \_ -> Expect.equal 0 (Bytes.width bytes)
                                                            , \_ -> Expect.equal None oldFrameAction
                                                            , \_ -> Expect.equal None errorAction
                                                            , \_ -> Expect.within (Expect.Absolute 0.000001) 75.5 secondDelay
                                                            , \_ -> Expect.within (Expect.Absolute 0.000001) 45.25 lastDelay
                                                            , \_ -> Expect.equal None staleAction
                                                            , \_ -> expectTimeout handle lastWake final
                                                            ]
                                                            ()

                                                    _ ->
                                                        Expect.fail "expected a remaining fractional wait, not an early timeout"

                                            _ ->
                                                Expect.fail "expected malformed JSON to count as activity without a clock read"

                                    _ ->
                                        Expect.fail "expected the first timer to move to the latest activity deadline"

                            _ ->
                                Expect.fail "expected a binary heartbeat without a new timer"
         , test "a delayed timer waits at most one full timeout after a newer native event" <|
            \_ ->
                watching config <|
                    \model handle _ wake ->
                        let
                            ( active, activityAction, _ ) =
                                Connection.update (SocketEvent.at (epoch + 1000.125) handle (Ws.Text "late activity")) model
                        in
                        case Connection.update wake active of
                            ( rescheduled, CheckAfter delay nextWake, Nothing ) ->
                                Expect.all
                                    [ \_ -> Expect.equal None activityAction
                                    , \_ -> Expect.equal 100 delay
                                    , \_ -> Expect.equal (Just handle) (Connection.get rescheduled)
                                    , \_ -> expectTimeout handle nextWake rescheduled
                                    ]
                                    ()

                            _ ->
                                Expect.fail "expected a bounded wait based on the latest known event time"
         , test "browser-sized sleep chunks advance only by their requested duration" <|
            \_ ->
                watching (config |> Connection.withServerTimeout (2 * 2147483647)) <|
                    \model handle firstDelay firstWake ->
                        case Connection.update firstWake model of
                            ( rescheduled, CheckAfter secondDelay secondWake, Nothing ) ->
                                Expect.all
                                    [ \_ -> Expect.equal 2147483647 firstDelay
                                    , \_ -> Expect.equal 2147483647 secondDelay
                                    , \_ -> expectTimeout handle secondWake rescheduled
                                    ]
                                    ()

                            _ ->
                                Expect.fail "expected another sleep instead of jumping to the full deadline"
         , test "checks are disabled by default and for nonpositive or non-finite durations" <|
            \_ ->
                let
                    default =
                        Connection.config "wss://example.com/socket"

                    check settings _ =
                        case Connection.init settings of
                            ( initial, Open handle _ _ ) ->
                                let
                                    ( connected, action, _ ) =
                                        Connection.update (SocketEvent.at epoch handle (Ws.Connected Nothing)) initial

                                    ( unchanged, activityAction, _ ) =
                                        Connection.update (SocketEvent.at (epoch + 10) handle (Ws.Text "hello")) connected
                                in
                                Expect.equal ( Just handle, None, None ) ( Connection.get unchanged, action, activityAction )

                            _ ->
                                Expect.fail "expected an initial socket"
                in
                Expect.all
                    (List.map check (default :: List.map (\duration -> Connection.withServerTimeout duration default) [ 0, -1, 0 / 0, 1 / 0 ]))
                    ()
         ]
            ++ List.map retiredAttempt [ False, True ]
        )


{-| A current watchdog expires exactly once and follows the retry policy.
-}
expectTimeout : Ws.Handle -> Connection.Msg -> Connection.Model -> Expect.Expectation
expectTimeout handle wake model =
    case Connection.update wake model of
        ( waiting, Close closed (Just ( delay, _ )), Nothing ) ->
            let
                ( unchanged, duplicateAction, _ ) =
                    Connection.update wake waiting
            in
            Expect.all
                [ \_ -> Expect.equal handle closed
                , \_ -> Expect.equal 0 delay
                , \_ -> Expect.equal (Remote.WaitingForRetry { attempts = 1, lastError = Connection.ServerTimeout }) (Connection.state waiting)
                , \_ -> Expect.equal Nothing (Connection.get waiting)
                , \_ -> Expect.equal None duplicateAction
                , \_ -> Expect.equal (Connection.state waiting) (Connection.state unchanged)
                ]
                ()

        _ ->
            Expect.fail "expected timeout at the logical deadline"


{-| Old timer callbacks cannot affect a replacement, even with handle reuse.
-}
retiredAttempt : Bool -> Test
retiredAttempt reuse =
    test
        (if reuse then
            "retired callbacks are ignored with handle reuse"

         else
            "retired callbacks are ignored with fresh handles"
        )
    <|
        \_ ->
            watching (config |> Connection.withHandleReuse reuse |> Connection.withLimit (MaxAttempts 1)) <|
                \model first _ oldWake ->
                    case Connection.reconnect model of
                        ( restarting, Replace _ second _ _ ) ->
                            case Connection.update (SocketEvent.at (epoch + 500.5) second (Ws.Connected Nothing)) restarting of
                                ( connected, CheckAfter delay wake, Just (Connection.Established Nothing) ) ->
                                    let
                                        ( afterTimer, oldTimerAction, _ ) =
                                            Connection.update oldWake connected
                                    in
                                    case Connection.update wake afterTimer of
                                        ( exhausted, Close closed Nothing, Nothing ) ->
                                            let
                                                ( unchanged, duplicateAction, _ ) =
                                                    Connection.update wake exhausted
                                            in
                                            Expect.all
                                                [ \_ -> Expect.equal reuse (first == second)
                                                , \_ -> Expect.equal 100 delay
                                                , \_ -> Expect.equal None oldTimerAction
                                                , \_ -> Expect.equal second closed
                                                , \_ -> Expect.equal (Remote.Failed Connection.ServerTimeout) (Connection.state exhausted)
                                                , \_ -> Expect.equal None duplicateAction
                                                , \_ -> Expect.equal (Connection.state exhausted) (Connection.state unchanged)
                                                ]
                                                ()

                                        _ ->
                                            Expect.fail "expected the new connection's timeout to exhaust its policy"

                                _ ->
                                    Expect.fail "expected the replacement watchdog with a fresh epoch"

                        _ ->
                            Expect.fail "expected a replacement socket"


{-| Establish a connection and return its first watchdog callback.
-}
watching : Connection.Config -> (Connection.Model -> Ws.Handle -> Float -> Connection.Msg -> Expect.Expectation) -> Expect.Expectation
watching settings scenario =
    case Connection.init settings of
        ( initial, Open handle _ _ ) ->
            case Connection.update (SocketEvent.at epoch handle (Ws.Connected Nothing)) initial of
                ( connected, CheckAfter delay wake, Just (Connection.Established Nothing) ) ->
                    scenario connected handle delay wake

                _ ->
                    Expect.fail "expected establishment to schedule the watchdog without a clock read"

        _ ->
            Expect.fail "expected an initial socket"
