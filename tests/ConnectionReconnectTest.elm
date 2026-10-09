module ConnectionReconnectTest exposing (tests)

{-| Exercises explicit restarts and caller failures across connection states.
-}

import Again.Policy exposing (AttemptLimit(..))
import Again.Remote as Remote
import Again.Schedule exposing (Schedule(..))
import Expect
import Test exposing (Test, describe, test)
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection exposing (Action(..))


{-| Reconnection must preserve transport configuration and a bounded retry policy.
-}
settings : Connection.Config
settings =
    Connection.config "wss://example.com/restart"
        |> Connection.withHandle (Ws.handle "caller")
        |> Connection.withProtocols [ "example.v1" ]
        |> Connection.withSchedule (ExponentialBackoff { initialDelay = 1000, multiplier = 2, maxDelay = 60000 })
        |> Connection.withLimit (MaxAttempts 2)


{-| A lifecycle state and the socket identity it most recently used.
-}
type alias Scenario =
    { name : String
    , model : Connection.Model
    , handle : Ws.Handle
    , active : Bool
    }


{-| Checks both transport identity modes without sleeping or opening sockets.
-}
tests : Test
tests =
    describe "Caller-initiated reconnects"
        (List.map
            (\reuse ->
                test
                    (if reuse then
                        "restart every lifecycle state with a reused handle"

                     else
                        "restart every lifecycle state with fresh handles"
                    )
                <|
                    \_ ->
                        case Connection.init (Connection.withHandleReuse reuse settings) of
                            ( initial, Open first _ _ ) ->
                                let
                                    ( connected, _, _ ) =
                                        Connection.update (Connection.receive ( first, Ws.Connected Nothing )) initial
                                in
                                case Connection.fail "initial failure" connected of
                                    ( waiting, Close _ (Just ( _, oldRetry )) ) ->
                                        case Connection.update oldRetry waiting of
                                            ( retrying, Open second _ _, _ ) ->
                                                case Connection.fail "retry failed" retrying of
                                                    ( exhausted, Close _ Nothing ) ->
                                                        [ { name = "connecting", model = initial, handle = first, active = True }
                                                        , { name = "connected", model = connected, handle = first, active = True }
                                                        , { name = "backoff", model = waiting, handle = first, active = False }
                                                        , { name = "retrying", model = retrying, handle = second, active = True }
                                                        , { name = "exhausted", model = exhausted, handle = second, active = False }
                                                        ]
                                                            |> List.map (\scenario _ -> checkRestart reuse oldRetry scenario)
                                                            |> (\checks -> Expect.all checks ())

                                                    _ ->
                                                        Expect.fail "expected the second caller failure to exhaust the policy"

                                            _ ->
                                                Expect.fail "expected an ordinary retry"

                                    _ ->
                                        Expect.fail "expected the caller failure to schedule a retry"

                            _ ->
                                Expect.fail "expected the initial socket"
            )
            [ False, True ]
        )


{-| Check immediate replacement, restored budget, and rejection of an old wakeup.
-}
checkRestart : Bool -> Connection.Msg -> Scenario -> Expect.Expectation
checkRestart reuse oldRetry scenario =
    let
        ( restarted, action ) =
            Connection.reconnect scenario.model

        opening =
            case ( scenario.active, action ) of
                ( True, Replace old handle url protocols ) ->
                    if old == scenario.handle then
                        Just ( handle, url, protocols )

                    else
                        Nothing

                ( False, Open handle url protocols ) ->
                    Just ( handle, url, protocols )

                _ ->
                    Nothing
    in
    case opening of
        Just ( handle, url, protocols ) ->
            case Connection.fail "new failure" restarted of
                ( waiting, Close closing (Just ( delay, retry )) ) ->
                    let
                        ( afterStale, staleAction, staleEvent ) =
                            Connection.update oldRetry waiting

                        ( afterDuplicate, duplicateAction ) =
                            Connection.fail "duplicate failure" afterStale
                    in
                    Expect.all
                        [ \_ -> Expect.equal reuse (scenario.handle == handle)
                        , \_ -> Expect.equal ( "wss://example.com/restart", [ "example.v1" ] ) ( url, protocols )
                        , \_ -> Expect.equal Remote.Attempting (Connection.state restarted)
                        , \_ -> Expect.equal Nothing (Connection.get restarted)
                        , \_ -> Expect.equal handle closing
                        , \_ -> Expect.equal 1000 delay
                        , \_ -> Expect.equal (Remote.WaitingForRetry { attempts = 1, lastError = Connection.ApplicationError "new failure" }) (Connection.state waiting)
                        , \_ -> Expect.equal None staleAction
                        , \_ -> Expect.equal Nothing staleEvent
                        , \_ -> Expect.equal (Connection.state waiting) (Connection.state afterStale)
                        , \_ -> Expect.equal None duplicateAction
                        , \_ -> Expect.equal (Connection.state waiting) (Connection.state afterDuplicate)
                        , \_ -> checkLimit retry afterDuplicate
                        , \_ ->
                            if reuse then
                                Expect.pass

                            else
                                let
                                    ( unchanged, lateAction, lateEvent ) =
                                        Connection.update (Connection.receive ( scenario.handle, Ws.Disconnected closed )) restarted
                                in
                                Expect.equal ( Remote.Attempting, None, Nothing ) ( Connection.state unchanged, lateAction, lateEvent )
                        , \_ ->
                            let
                                ( connected, establishedAction, event ) =
                                    Connection.update (Connection.receive ( handle, Ws.Connected (Just "example.v1") )) restarted
                            in
                            Expect.equal ( Just handle, None, Just (Connection.Established (Just "example.v1")) ) ( Connection.get connected, establishedAction, event )
                        ]
                        ()

                _ ->
                    Expect.fail ("expected a fresh retry budget after reconnecting from " ++ scenario.name)

        Nothing ->
            Expect.fail ("expected immediate open or replacement from " ++ scenario.name)


{-| A restarted sequence still respects its configured limit and terminal state.
-}
checkLimit : Connection.Msg -> Connection.Model -> Expect.Expectation
checkLimit retry model =
    case Connection.update retry model of
        ( attempting, Open handle _ _, Nothing ) ->
            let
                ( exhausted, action ) =
                    Connection.fail "second failure" attempting

                ( unchanged, duplicateAction ) =
                    Connection.fail "ignored" exhausted
            in
            Expect.all
                [ \_ -> Expect.equal (Close handle Nothing) action
                , \_ -> Expect.equal (Remote.Failed (Connection.ApplicationError "second failure")) (Connection.state exhausted)
                , \_ -> Expect.equal None duplicateAction
                , \_ -> Expect.equal (Connection.state exhausted) (Connection.state unchanged)
                ]
                ()

        _ ->
            Expect.fail "expected the new retry callback to open one socket"


{-| A late close from the replaced socket must not affect its replacement.
-}
closed : Ws.CloseDetails
closed =
    { code = 1000, reason = "", wasClean = True, initiatedLocally = True }
