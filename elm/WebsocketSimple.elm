port module WebsocketSimple exposing (Cmd(..), Msg(..), send, subscribe)

import Json.Decode as D
import Json.Encode as E
import Json.Encode.Extra as Ex
import Platform.Cmd
import Result.Extra


subscribe : D.Decoder wmsg -> Sub (Msg wmsg)
subscribe decoder =
    wsMsg (decodeWsMsg decoder)


type alias WebSocketHandle =
    String


type alias Url =
    String


type Cmd
    = Open Url (Maybe String)
    | Close (Maybe Int) (Maybe String)


type Msg wmsg
    = Openend
    | Closed
    | Text wmsg
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

        Close code reason ->
            ( "close"
            , E.object
                [ ( "code", Ex.maybe E.int code )
                , ( "reason", Ex.maybe E.string reason )
                ]
            )


decodeHelper : D.Decoder v -> (v -> Msg wmsg) -> D.Value -> Msg wmsg
decodeHelper decoder map value =
    D.decodeValue decoder value
        |> Result.map map
        |> Result.Extra.extract
            (\e -> Error ("decoding error in incoming channel message: " ++ D.errorToString e))


decodeWsMsg : D.Decoder wmsg -> ( String, E.Value ) -> Msg wmsg
decodeWsMsg msgDecoder ( kind, data ) =
    case kind of
        "open" ->
            Openend

        "close" ->
            Closed

        "error" ->
            decodeHelper D.string Error data

        "message" ->
            decodeHelper msgDecoder Text data

        _ ->
            Error ("Received an invalid message through channel: " ++ kind)


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
port wsMsg : (( String, E.Value ) -> msg) -> Sub msg
