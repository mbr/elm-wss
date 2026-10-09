module ConnectionTimeoutTest exposing (tests)

{-| Drives the inactivity watchdog with explicit timestamps instead of real timers.
-}

import Again.Policy exposing (AttemptLimit(..))
import Again.Remote as Remote
import Bytes
import Bytes.Encode as BytesEncode
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Time exposing (Posix)
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection exposing (Action(..))
import WebsocketSimple.Connection.Json as Json


{-| A short timeout keeps deadline arithmetic readable.
-}
config : Connection.Config
config =
    Connection.config "wss://example.com/socket" |> Connection.withServerTimeout 100


{-| Checks lazy rescheduling, delayed clocks, retired attempts, and disabled checks.
-}
tests : Test
tests =
    describe "Server inactivity timeout"
        ([ test "empty binary frames and malformed JSON postpone expiry without restarting the timer" <|
            \_ ->
                watching config <|
                    \model handle firstDeadline firstWake ->
                        let
                            empty =
                                BytesEncode.encode (BytesEncode.sequence [])

                            error =
                                { kind = Ws.UnsupportedData, message = "unsupported" }

                            ( afterError, errorAction, _ ) =
                                Connection.update (Connection.receive ( handle, Ws.TransportError error )) model
                        in
                        case Json.update Decode.int (Connection.receive ( handle, Ws.Binary empty )) afterError of
                            ( pending, ReadTime binaryClock, Just (Json.Binary bytes) ) ->
                                let
                                    ( received, activityAction, _ ) =
                                        Connection.update (binaryClock (at 75)) pending
                                in
                                case Connection.update (firstWake (at 95)) received of
                                    ( extended, CheckAt secondDeadline secondWake, Nothing ) ->
                                        case Json.update Decode.int (Connection.receive ( handle, Ws.Text "not JSON" )) extended of
                                            ( textPending, ReadTime textClock, Just (Json.PayloadDecodeFailure _ _) ) ->
                                                let
                                                    ( textReceived, textAction, _ ) =
                                                        Connection.update (textClock (at 120)) textPending

                                                    ( unchanged, staleAction, _ ) =
                                                        Connection.update (firstWake (at 150)) textReceived
                                                in
                                                case Connection.update (secondWake (at 230)) unchanged of
                                                    ( waiting, Close closed (Just ( delay, _ )), Nothing ) ->
                                                        Expect.all
                                                            [ \_ -> Expect.equal (at 100) firstDeadline
                                                            , \_ -> Expect.equal None errorAction
                                                            , \_ -> Expect.equal 0 (Bytes.width bytes)
                                                            , \_ -> Expect.equal None activityAction
                                                            , \_ -> Expect.equal (at 175) secondDeadline
                                                            , \_ -> Expect.equal None textAction
                                                            , \_ -> Expect.equal None staleAction
                                                            , \_ -> Expect.equal handle closed
                                                            , \_ -> Expect.equal 0 delay
                                                            , \_ -> Expect.equal (Remote.WaitingForRetry { attempts = 1, lastError = Connection.ServerTimeout }) (Connection.state waiting)
                                                            , \_ -> Expect.equal Nothing (Connection.get waiting)
                                                            ]
                                                            ()

                                                    _ ->
                                                        Expect.fail "expected a late wakeup to fail the silent connection"

                                            _ ->
                                                Expect.fail "expected malformed JSON to count as activity"

                                    _ ->
                                        Expect.fail "expected the first timer to move to the latest activity deadline"

                            _ ->
                                Expect.fail "expected an empty binary frame and one clock read"
         , test "a receipt awaiting its clock reading prevents premature expiry and older clock replies are ignored" <|
            \_ ->
                watching config <|
                    \model handle _ wake ->
                        case Connection.update (Connection.receive ( handle, Ws.Text "first" )) model of
                            ( firstPending, ReadTime firstClock, _ ) ->
                                case Connection.update (Connection.receive ( handle, Ws.Text "second" )) firstPending of
                                    ( secondPending, ReadTime secondClock, _ ) ->
                                        let
                                            ( afterOldClock, oldClockAction, _ ) =
                                                Connection.update (firstClock (at 90)) secondPending

                                            ( expired, expiryAction, _ ) =
                                                Connection.update (wake (at 100)) afterOldClock
                                        in
                                        case Connection.update (secondClock (at 95)) expired of
                                            ( received, CheckAt nextDeadline nextWake, Nothing ) ->
                                                let
                                                    ( duplicate, duplicateAction, _ ) =
                                                        Connection.update (secondClock (at 1000)) received

                                                    ( unchanged, oldTimerAction, _ ) =
                                                        Connection.update (wake (at 1000)) duplicate
                                                in
                                                Expect.all
                                                    [ \_ -> Expect.equal None oldClockAction
                                                    , \_ -> Expect.equal None expiryAction
                                                    , \_ -> Expect.equal (Just handle) (Connection.get expired)
                                                    , \_ -> Expect.equal (at 195) nextDeadline
                                                    , \_ -> Expect.equal None duplicateAction
                                                    , \_ -> Expect.equal None oldTimerAction
                                                    , \_ ->
                                                        case Connection.update (nextWake nextDeadline) unchanged of
                                                            ( _, Close closed (Just _), Nothing ) ->
                                                                Expect.equal handle closed

                                                            _ ->
                                                                Expect.fail "expected expiry at the newest receipt's deadline"
                                                    ]
                                                    ()

                                            _ ->
                                                Expect.fail "expected one timer after the latest clock reply"

                                    _ ->
                                        Expect.fail "expected the second activity clock read"

                            _ ->
                                Expect.fail "expected the first activity clock read"
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
                                        Connection.update (Connection.receive ( handle, Ws.Connected Nothing )) initial

                                    ( unchanged, activityAction, _ ) =
                                        Connection.update (Connection.receive ( handle, Ws.Text "hello" )) connected
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


{-| Old clock and timer callbacks cannot affect a replacement, even with handle reuse.
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
                    case Connection.update (Connection.receive ( first, Ws.Text "late" )) model of
                        ( pending, ReadTime oldClock, _ ) ->
                            case Connection.reconnect pending of
                                ( restarting, Replace _ second _ _ ) ->
                                    case Connection.update (Connection.receive ( second, Ws.Connected Nothing )) restarting of
                                        ( established, ReadTime newClock, _ ) ->
                                            case Connection.update (newClock (at 500)) established of
                                                ( connected, CheckAt expires wake, Nothing ) ->
                                                    let
                                                        ( afterTimer, oldTimerAction, _ ) =
                                                            Connection.update (oldWake (at 10000)) connected

                                                        ( afterClock, oldClockAction, _ ) =
                                                            Connection.update (oldClock (at 20000)) afterTimer
                                                    in
                                                    case Connection.update (wake expires) afterClock of
                                                        ( exhausted, Close closed Nothing, Nothing ) ->
                                                            let
                                                                ( unchanged, duplicateAction, _ ) =
                                                                    Connection.update (wake (at 1000)) exhausted
                                                            in
                                                            Expect.all
                                                                [ \_ -> Expect.equal reuse (first == second)
                                                                , \_ -> Expect.equal (at 600) expires
                                                                , \_ -> Expect.equal None oldTimerAction
                                                                , \_ -> Expect.equal None oldClockAction
                                                                , \_ -> Expect.equal second closed
                                                                , \_ -> Expect.equal (Remote.Failed Connection.ServerTimeout) (Connection.state exhausted)
                                                                , \_ -> Expect.equal None duplicateAction
                                                                , \_ -> Expect.equal (Connection.state exhausted) (Connection.state unchanged)
                                                                ]
                                                                ()

                                                        _ ->
                                                            Expect.fail "expected the new connection's timeout to exhaust its policy"

                                                _ ->
                                                    Expect.fail "expected the replacement watchdog"

                                        _ ->
                                            Expect.fail "expected a clock read for the replacement"

                                _ ->
                                    Expect.fail "expected a replacement socket"

                        _ ->
                            Expect.fail "expected an outstanding activity clock read"


{-| Establish a connection and return its first watchdog callback.
-}
watching : Connection.Config -> (Connection.Model -> Ws.Handle -> Posix -> (Posix -> Connection.Msg) -> Expect.Expectation) -> Expect.Expectation
watching settings scenario =
    case Connection.init settings of
        ( initial, Open handle _ _ ) ->
            case Connection.update (Connection.receive ( handle, Ws.Connected Nothing )) initial of
                ( connected, ReadTime clock, Just (Connection.Established Nothing) ) ->
                    case Connection.update (clock (at 0)) connected of
                        ( model, CheckAt expires wake, Nothing ) ->
                            scenario model handle expires wake

                        _ ->
                            Expect.fail "expected the first watchdog timer"

                _ ->
                    Expect.fail "expected establishment to request the current time"

        _ ->
            Expect.fail "expected an initial socket"


{-| Construct a deterministic clock reading.
-}
at : Int -> Posix
at =
    Time.millisToPosix
