module ConnectionJsonTest exposing (tests)

{-| Exercises JSON adaptation without changing the managed connection lifecycle.
-}

import Bytes.Decode as BytesDecode
import Bytes.Encode as BytesEncode
import Expect
import Json.Decode as Decode
import SocketEvent
import Test exposing (Test, describe, test)
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection
import WebsocketSimple.Connection.Json as Json


{-| Covers typed messages, unchanged non-text events, decoding failures, and retries.
-}
tests : Test
tests =
    describe "Managed JSON connections"
        [ test "decodes accepted text and preserves establishment, binary frames, and application errors" <|
            \_ ->
                started <|
                    \initial handle ->
                        let
                            ( connected, establishedAction, established ) =
                                incoming handle (Ws.Connected (Just "json.v1")) initial

                            ( received, textAction, textEvent ) =
                                incoming handle (Ws.Text "{\"count\":7}") connected

                            ( binary, binaryAction, binaryEvent ) =
                                incoming handle (Ws.Binary (BytesEncode.encode (BytesEncode.string "raw"))) received

                            error =
                                { kind = Ws.SendRejection, message = "rejected" }

                            ( unchanged, errorAction, errorEvent ) =
                                incoming handle (Ws.TransportError error) binary
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (Json.Established (Just "json.v1"))) established
                            , \_ -> Expect.equal (Just (Json.Received 7)) textEvent
                            , \_ ->
                                case binaryEvent of
                                    Just (Json.Binary bytes) ->
                                        Expect.equal (Just "raw") (BytesDecode.decode (BytesDecode.string 3) bytes)

                                    _ ->
                                        Expect.fail "expected an unchanged binary frame"
                            , \_ -> Expect.equal (Just (Json.Error error)) errorEvent
                            , \_ -> Expect.equal (List.repeat 4 Connection.None) [ establishedAction, textAction, binaryAction, errorAction ]
                            , \_ -> Expect.equal (Just handle) (Connection.get unchanged)
                            ]
                            ()
        , test "syntax and schema failures retain the text and error without disconnecting" <|
            \_ ->
                started <|
                    \initial handle ->
                        let
                            ( connected, _, _ ) =
                                incoming handle (Ws.Connected Nothing) initial

                            check body _ =
                                case ( incoming handle (Ws.Text body) connected, Decode.decodeString decoder body ) of
                                    ( ( failed, action, Just (Json.PayloadDecodeFailure original error) ), Err expected ) ->
                                        let
                                            ( recovered, _, event ) =
                                                incoming handle (Ws.Text "{\"count\":8}") failed
                                        in
                                        Expect.all
                                            [ \_ -> Expect.equal body original
                                            , \_ -> Expect.equal (Decode.errorToString expected) (Decode.errorToString error)
                                            , \_ -> Expect.equal Connection.None action
                                            , \_ -> Expect.equal (Connection.state connected) (Connection.state failed)
                                            , \_ -> Expect.equal (Just handle) (Connection.get recovered)
                                            , \_ -> Expect.equal (Just (Json.Received 8)) event
                                            ]
                                            ()

                                    _ ->
                                        Expect.fail "expected the original text and decoding error"
                        in
                        Expect.all (List.map check [ "not JSON", "{\"count\":\"wrong type\"}", "{}" ]) ()
        , test "filters retired sockets before decoding and preserves retry actions" <|
            \_ ->
                started <|
                    \initial first ->
                        let
                            ( connected, _, _ ) =
                                incoming first (Ws.Connected Nothing) initial
                        in
                        case Connection.fail "Update sequence gap" connected of
                            ( waiting, Connection.Close _ (Just ( _, retry )) ) ->
                                case Json.update decoder retry waiting of
                                    ( attempting, Connection.Open second _ _, Nothing ) ->
                                        let
                                            ( unchanged, staleAction, staleEvent ) =
                                                incoming first (Ws.Text "not JSON") attempting

                                            error =
                                                { kind = Ws.BrowserFailure, message = "lost" }
                                        in
                                        case incoming second (Ws.TransportError error) unchanged of
                                            ( failed, Connection.Close closing (Just _), Nothing ) ->
                                                Expect.all
                                                    [ \_ -> Expect.equal Connection.None staleAction
                                                    , \_ -> Expect.equal Nothing staleEvent
                                                    , \_ -> Expect.equal (Connection.state attempting) (Connection.state unchanged)
                                                    , \_ -> Expect.notEqual first second
                                                    , \_ -> Expect.equal second closing
                                                    , \_ -> Expect.equal Nothing (Connection.get failed)
                                                    ]
                                                    ()

                                            _ ->
                                                Expect.fail "expected a transport failure to retain its retry action"

                                    _ ->
                                        Expect.fail "expected the retry message to open a replacement socket"

                            _ ->
                                Expect.fail "expected application failure to schedule a retry"
        ]


{-| Decode a typed field rather than retaining unvalidated JSON.
-}
decoder : Decode.Decoder Int
decoder =
    Decode.field "count" Decode.int


{-| Feed a handled transport event through the JSON adapter.
-}
incoming : Ws.Handle -> Ws.RawMsg -> Connection.Model -> ( Connection.Model, Connection.Action, Maybe (Json.Event Int) )
incoming handle event =
    Json.update decoder (SocketEvent.at 0 handle event)


{-| Supply a pending connection and its initial socket handle.
-}
started : (Connection.Model -> Ws.Handle -> Expect.Expectation) -> Expect.Expectation
started scenario =
    case Connection.init (Connection.config "wss://example.com/socket") of
        ( initial, Connection.Open handle _ _ ) ->
            scenario initial handle

        _ ->
            Expect.fail "expected an initial socket"
