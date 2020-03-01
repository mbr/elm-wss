port module WebsocketSimple exposing (Cmd(..), Msg(..), send, subscribe, subscribeAny)

import Json.Decode as D
import Json.Encode as E
import Json.Encode.Extra as Ex
import Platform.Cmd
import Result.Extra


{-| A handler is given a websocket handle and a message and turns it into a an
application message
-}
type alias Handler msg =
    String -> Msg -> msg


subscribe : Handler msg -> Sub msg
subscribe handler =
    wsMsg (decodeWsMsg handler)


subscribeAny : Sub Msg
subscribeAny =
    subscribe (\_ msg -> msg)


type alias WebSocketHandle =
    String


type alias Url =
    String



{- -}


type Cmd
    = Open Url (Maybe String)
    | Transmit String
    | Close (Maybe Int) (Maybe String)


type Msg
    = Established
    | Closed
    | Text String
    | Error String


encodeWsCmd : Cmd -> ( String, E.Value )
encodeWsCmd cmd =
    case cmd of
        Open url protocol ->
            ( "open"
            , E.object
                [ ( "url", E.string url )
                , ( "protocol", Ex.maybe E.string protocol )
                ]
            )

        Transmit data ->
            ( "transmit", E.string data )

        Close code reason ->
            ( "close"
            , E.object
                [ ( "code", Ex.maybe E.int code )
                , ( "reason", Ex.maybe E.string reason )
                ]
            )


decodeHelper : D.Decoder v -> (v -> Msg) -> D.Value -> Msg
decodeHelper decoder map value =
    D.decodeValue decoder value
        |> Result.map map
        |> Result.Extra.extract
            (\e -> Error ("decoding error in incoming channel message: " ++ D.errorToString e))


decodeWsMsg : Handler msg -> ( String, String, E.Value ) -> msg
decodeWsMsg handler ( handle, kind, data ) =
    handler handle
        (case kind of
            "established" ->
                Established

            "closed" ->
                Closed

            "error" ->
                decodeHelper D.string Error data

            "message" ->
                decodeHelper D.string Text data

            _ ->
                Error ("Received an invalid message through channel: " ++ kind)
        )


send : Cmd -> WebSocketHandle -> Platform.Cmd.Cmd msg
send cmd handle =
    let
        ( cmdString, data ) =
            encodeWsCmd cmd
    in
    wsCmd ( handle, cmdString, data )


{-| Websocket outgoing port.

Data is sent out as `(handle, command, data)`.

-}
port wsCmd : ( WebSocketHandle, String, E.Value ) -> Platform.Cmd.Cmd msg


{-| Websocket incoming port.
-}
port wsMsg : (( String, String, E.Value ) -> msg) -> Sub msg
