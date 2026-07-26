{- Copyright (c) 2020 Marc Brinkmann

   Permission is hereby granted, free of charge, to any person obtaining a
   copy of this software and associated documentation files (the "Software"),
   to deal in the Software without restriction, including without limitation
   the rights to use, copy, modify, merge, publish, distribute, sublicense,
   and/or sell copies of the Software, and to permit persons to whom the
   Software is furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.
-}


port module WebsocketSimple exposing
    ( CloseDetails
    , Cmd(..)
    , Msg(..)
    , RawMsg(..)
    , TransportErrorDetails
    , TransportErrorKind(..)
    , close
    , errorKindToString
    , errorToString
    , open
    , parseIncoming
    , send
    , sendWithHandle
    , subscribe
    , subscribeMsg
    , subscribeWithHandle
    , transmitMsg
    )

{-| The simple websockets module.

To get start, ensure the runtime is installed (`elm-websockets.js`) and
called. Subscribe to websocket messages through `subscribe`, send them using
`send`. That's it.

-}

import Json.Decode as D
import Json.Encode as E
import Platform.Cmd


{-| A handle identifies a particular websocket
-}
type alias WebSocketHandle =
    String


{-| Websocket URL to connect to (`ws://..` or `ws:///...`)
-}
type alias Url =
    String


{-| Details supplied when a websocket closes
-}
type alias CloseDetails =
    { code : Int
    , reason : String
    , wasClean : Bool
    , initiatedLocally : Bool
    }


{-| Categorizes a websocket transport error
-}
type TransportErrorKind
    = ConstructionFailure
    | SendFailure
    | CloseFailure
    | BrowserFailure
    | SendRejection
    | UnsupportedData
    | PortDecodingFailure


{-| Describes a websocket transport error
-}
type alias TransportErrorDetails =
    { kind : TransportErrorKind
    , message : String
    }


{-| Render a transport error as a readable string
-}
errorToString : TransportErrorDetails -> String
errorToString error =
    "[" ++ errorKindToString error.kind ++ "] " ++ error.message


{-| Render a transport error kind as a readable string
-}
errorKindToString : TransportErrorKind -> String
errorKindToString kind =
    case kind of
        ConstructionFailure ->
            "ConstructionFailure"

        SendFailure ->
            "SendFailure"

        CloseFailure ->
            "CloseFailure"

        BrowserFailure ->
            "BrowserFailure"

        SendRejection ->
            "SendRejection"

        UnsupportedData ->
            "UnsupportedData"

        PortDecodingFailure ->
            "PortDecodingFailure"


{-| Subscribe for incoming messages tagged with handler

Yields tuples of `(handler, msg)`

-}
subscribeWithHandle : Sub ( WebSocketHandle, RawMsg )
subscribeWithHandle =
    wsMsg decodeWsMsg


{-| Subscribe for incoming messages, discarding handler information
-}
subscribe : Sub RawMsg
subscribe =
    Sub.map Tuple.second subscribeWithHandle


{-| Subscribe and parse JSON of incoming messages, discarding handler info
-}
subscribeMsg : D.Decoder t -> (Msg t -> msg) -> Sub msg
subscribeMsg dec wrap =
    Sub.map (parseIncoming dec >> wrap) subscribe


{-| Send a message to a websocket specified by handle
-}
sendWithHandle : WebSocketHandle -> Cmd -> Platform.Cmd.Cmd msg
sendWithHandle handle cmd =
    let
        ( cmdString, data ) =
            encodeWsCmd cmd
    in
    wsCmd ( handle, cmdString, data )


{-| Send a command to `default` socket
-}
send : Cmd -> Platform.Cmd.Cmd msg
send =
    sendWithHandle "default"


{-| Connect to a specified socket as default
-}
open : String -> Platform.Cmd.Cmd msg
open url =
    send <| Open url Nothing


{-| Close the default connection
-}
close : Platform.Cmd.Cmd msg
close =
    send <| Close Nothing Nothing


{-| JSON-encode a message and send it to the `default` socket
-}
transmitMsg : (t -> E.Value) -> t -> Platform.Cmd.Cmd msg
transmitMsg enc msg =
    enc msg |> E.encode 0 |> Transmit |> send


{-| Command that can be sent to a websocket:

  - `Open` opens a connection to the specified URL, with an optional protocol
  - `Transmit` sends a text message string
  - `Close` closes the connection, with an optional code and reason

-}
type Cmd
    = Open Url (Maybe String)
    | Transmit String
    | Close (Maybe Int) (Maybe String)


{-| Messages that are received from websockets

  - `Connected` when the connection succeeds
  - `Disconnected` when the connection has been terminated, with close details
  - `Text` when a new text-message has arrived on the socket
  - `TransportError` on a transport or port error

-}
type RawMsg
    = Connected
    | Disconnected CloseDetails
    | Text String
    | TransportError TransportErrorDetails


{-| Typed messages received from websockets

When receiving JSON-encoded messages via websockets, this type keeps transport
errors separate from payload decoding failures.

-}
type Msg t
    = Established
    | Closed CloseDetails
    | Received t
    | TransportFailure TransportErrorDetails
    | PayloadDecodeFailure String D.Error


{-| Convert a `RawMsg` into a `Msg`
-}
parseIncoming : D.Decoder t -> RawMsg -> Msg t
parseIncoming decoder rawMsg =
    case rawMsg of
        Connected ->
            Established

        Disconnected details ->
            Closed details

        TransportError error ->
            TransportFailure error

        Text txt ->
            case D.decodeString decoder txt of
                Ok v ->
                    Received v

                Err error ->
                    PayloadDecodeFailure txt error


{-| Helper function to encode a command to be sent over the channel
-}
encodeWsCmd : Cmd -> ( String, E.Value )
encodeWsCmd cmd =
    case cmd of
        Open url protocol ->
            ( "open"
            , E.object
                [ ( "url", E.string url )
                , ( "protocol", maybe E.string protocol )
                ]
            )

        Transmit data ->
            ( "transmit", E.string data )

        Close code reason ->
            ( "close"
            , E.object
                [ ( "code", maybe E.int code )
                , ( "reason", maybe E.string reason )
                ]
            )


{-| Decode a JSON string, yield an `Err` on failure
-}
decodeHelper : D.Decoder v -> (v -> RawMsg) -> D.Value -> RawMsg
decodeHelper decoder map value =
    D.decodeValue decoder value
        |> Result.map map
        |> extract
            (\error ->
                TransportError
                    { kind = PortDecodingFailure
                    , message = "decoding error in incoming channel message: " ++ D.errorToString error
                    }
            )


{-| Decode a transport error kind
-}
decodeTransportErrorKind : D.Decoder TransportErrorKind
decodeTransportErrorKind =
    D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "construction" ->
                        D.succeed ConstructionFailure

                    "send" ->
                        D.succeed SendFailure

                    "close" ->
                        D.succeed CloseFailure

                    "transport" ->
                        D.succeed BrowserFailure

                    "send-rejection" ->
                        D.succeed SendRejection

                    "unsupported-data" ->
                        D.succeed UnsupportedData

                    _ ->
                        D.fail ("unknown transport error kind: " ++ kind)
            )


{-| Decode a transport error
-}
decodeTransportError : D.Decoder TransportErrorDetails
decodeTransportError =
    D.map2
        (\kind message ->
            { kind = kind
            , message = message
            }
        )
        (D.field "kind" decodeTransportErrorKind)
        (D.field "message" D.string)


{-| Decode websocket close details
-}
decodeCloseDetails : D.Decoder CloseDetails
decodeCloseDetails =
    D.map4 CloseDetails
        (D.field "code" D.int)
        (D.field "reason" D.string)
        (D.field "wasClean" D.bool)
        (D.field "initiatedLocally" D.bool)


{-| Decode an incoming websocket message from javascript
-}
decodeWsMsg : ( WebSocketHandle, String, E.Value ) -> ( WebSocketHandle, RawMsg )
decodeWsMsg ( handle, kind, data ) =
    ( handle
    , case kind of
        "connected" ->
            Connected

        "disconnected" ->
            decodeHelper decodeCloseDetails Disconnected data

        "error" ->
            decodeHelper decodeTransportError TransportError data

        "message" ->
            decodeHelper D.string Text data

        _ ->
            TransportError
                { kind = PortDecodingFailure
                , message = "received an invalid message through channel: " ++ kind
                }
    )


{-| Websocket outgoing port.

Data is sent out as `(handle, command, data)`.

-}
port wsCmd : ( WebSocketHandle, String, E.Value ) -> Platform.Cmd.Cmd msg


{-| Websocket incoming port.
-}
port wsMsg : (( WebSocketHandle, String, E.Value ) -> msg) -> Sub msg



-- Inlined library functions
-- from `Result.Extra`
{- Result.Extra is licensed using the MIT license

   The MIT License (MIT)

      Copyright (c) 2016-2019 CircuitHub Inc., Elm Community members

      Permission is hereby granted, free of charge, to any person obtaining a copy
      of this software and associated documentation files (the "Software"), to deal
      in the Software without restriction, including without limitation the rights
      to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
      copies of the Software, and to permit persons to whom the Software is
      furnished to do so, subject to the following conditions:

      The above copyright notice and this permission notice shall be included in all
      copies or substantial portions of the Software.

      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
      IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
      FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
      AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
      LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
      OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
      SOFTWARE.

-}


extract : (e -> a) -> Result e a -> a
extract f x =
    case x of
        Ok a ->
            a

        Err e ->
            f e



-- from `Json.Encode.Extra`
{- Json.Encode.Extra is licensed using the MIT License
   The MIT License (MIT)

   Copyright (c) 2016 CircuitHub Inc., Elm Community members

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE.



-}


maybe : (a -> E.Value) -> Maybe a -> E.Value
maybe encoder =
    Maybe.map encoder >> Maybe.withDefault E.null
