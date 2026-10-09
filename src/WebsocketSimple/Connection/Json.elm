module WebsocketSimple.Connection.Json exposing (Event(..), update, parseIncoming, send)

{-| JSON messages over a managed connection. Keep using `Connection.Model`,
`Connection.subscribe`, and `Connection.perform`; replace `Connection.update`
with `update`, supplying your message decoder.

    import Json.Decode as Decode
    import Json.Encode as Encode
    import WebsocketSimple.Connection as Connection
    import WebsocketSimple.Connection.Json as Json

    type alias Message =
        { text : String }

    decoder : Decode.Decoder Message
    decoder =
        Decode.map Message (Decode.field "text" Decode.string)

    encoder : Message -> Encode.Value
    encoder message =
        Encode.object [ ( "text", Encode.string message.text ) ]

    receive : Connection.Msg -> Connection.Model -> ( Connection.Model, Connection.Action, Maybe (Json.Event Message) )
    receive =
        Json.update decoder

To reply, use `Json.send Ports.wsCmd encoder message connection`.

A `PayloadDecodeFailure` retains the original text and decoding error without
changing the connection. Your application can report it, ignore it, or call
`Connection.fail` to reconnect according to its retry policy. Binary frames pass
through unchanged, unlike the JSON adapter in `WebsocketSimple`.

@docs Event, update, parseIncoming, send

-}

import Bytes exposing (Bytes)
import Json.Decode as Decode
import Json.Encode as Encode
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection


{-| Typed application events. `PayloadDecodeFailure` is separate from transport
errors; neither event automatically triggers reconnection.
-}
type Event value
    = Established (Maybe String)
    | Received value
    | PayloadDecodeFailure String Decode.Error
    | Binary Bytes
    | Error Ws.TransportErrorDetails


{-| Apply the connection transition, then decode any accepted text event. Socket
filtering, retry actions, and connection state follow `Connection.update`.
-}
update : Decode.Decoder value -> Connection.Msg -> Connection.Model -> ( Connection.Model, Connection.Action, Maybe (Event value) )
update decoder msg model =
    let
        ( connection, action, incoming ) =
            Connection.update msg model
    in
    ( connection, action, Maybe.map (parseIncoming decoder) incoming )


{-| Decode a text event while preserving establishment, binary data, and transport
errors. Use this to adapt individual events after calling `Connection.update`.
-}
parseIncoming : Decode.Decoder value -> Connection.Event -> Event value
parseIncoming decoder event =
    case event of
        Connection.Established protocol ->
            Established protocol

        Connection.Text body ->
            case Decode.decodeString decoder body of
                Ok value ->
                    Received value

                Err error ->
                    PayloadDecodeFailure body error

        Connection.Binary bytes ->
            Binary bytes

        Connection.Error error ->
            Error error


{-| Encode a value and send it as a text frame. Uses the same best-effort behavior
as `Connection.send`: disconnected sends are discarded without buffering or replay.
-}
send : Ws.CommandPort msg -> (value -> Encode.Value) -> value -> Connection.Model -> Cmd msg
send commandPort encoder value =
    Connection.send commandPort (Encode.encode 0 (encoder value))
