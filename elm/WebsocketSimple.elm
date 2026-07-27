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
    , CloseRequest
    , Cmd(..)
    , CommandPort
    , EventPort
    , Handle
    , Msg(..)
    , RawMsg(..)
    , TransportErrorDetails
    , TransportErrorKind(..)
    , close
    , errorKindToString
    , errorToString
    , handle
    , handleToString
    , open
    , parseIncoming
    , send
    , sendWithHandle
    , subscribe
    , subscribeMsg
    , subscribeMsgWithHandle
    , subscribeWithHandle
    , transmitMsg
    , transmitMsgWithHandle
    )

{-| The simple websockets module.

To get start, ensure the runtime is installed (`elm-websockets.js`) and
called. Subscribe to websocket messages through `subscribe`, send them using
`send`. That's it.

-}

import Json.Decode as D
import Json.Encode as E
import Platform.Cmd


{-| Sends encoded commands to the JavaScript runtime.
-}
type alias CommandPort msg =
    ( String, String, E.Value ) -> Platform.Cmd.Cmd msg


{-| Receives encoded events from the JavaScript runtime.
-}
type alias EventPort msg =
    (( String, String, E.Value ) -> msg) -> Sub msg


{-| Identifies a particular websocket
-}
type Handle
    = Handle String


{-| Construct a websocket handle
-}
handle : String -> Handle
handle =
    Handle


{-| Return a websocket handle's string representation
-}
handleToString : Handle -> String
handleToString (Handle value) =
    value


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


{-| Describes an application-requested close
-}
type alias CloseRequest =
    { code : Int
    , reason : String
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


{-| Subscribe for incoming messages tagged with their handle

Yields tuples of `(handle, msg)`

-}
subscribeWithHandle : Sub ( Handle, RawMsg )
subscribeWithHandle =
    wsMsg decodeWsMsg


{-| Subscribe for incoming messages, discarding handle information
-}
subscribe : Sub RawMsg
subscribe =
    Sub.map Tuple.second subscribeWithHandle


{-| Subscribe and parse JSON of incoming messages, discarding handle information
-}
subscribeMsg : D.Decoder t -> (Msg t -> msg) -> Sub msg
subscribeMsg dec wrap =
    Sub.map (parseIncoming dec >> wrap) subscribe


{-| Subscribe and parse JSON of incoming messages, preserving handle info
-}
subscribeMsgWithHandle : D.Decoder t -> (( Handle, Msg t ) -> msg) -> Sub msg
subscribeMsgWithHandle dec wrap =
    Sub.map
        (\( socketHandle, rawMsg ) ->
            wrap ( socketHandle, parseIncoming dec rawMsg )
        )
        subscribeWithHandle


{-| Send a message to a websocket specified by handle
-}
sendWithHandle : Handle -> Cmd -> Platform.Cmd.Cmd msg
sendWithHandle (Handle socketHandle) cmd =
    let
        ( cmdString, data ) =
            encodeWsCmd cmd
    in
    wsCmd ( socketHandle, cmdString, data )


{-| Send a command to `default` socket
-}
send : Cmd -> Platform.Cmd.Cmd msg
send =
    sendWithHandle (Handle "default")


{-| Connect to a specified socket as default
-}
open : String -> Platform.Cmd.Cmd msg
open url =
    send <| Open url []


{-| Close the default connection
-}
close : Platform.Cmd.Cmd msg
close =
    send <| Close Nothing


{-| JSON-encode a message and send it to the `default` socket
-}
transmitMsg : (t -> E.Value) -> t -> Platform.Cmd.Cmd msg
transmitMsg =
    transmitMsgWithHandle (Handle "default")


{-| JSON-encode a message and send it to a socket specified by handle
-}
transmitMsgWithHandle : Handle -> (t -> E.Value) -> t -> Platform.Cmd.Cmd msg
transmitMsgWithHandle socketHandle enc msg =
    enc msg |> E.encode 0 |> Transmit |> sendWithHandle socketHandle


{-| Command that can be sent to a websocket:

  - `Open` opens a connection to the specified URL with ordered subprotocols
  - `Transmit` sends a text message string
  - `Close` closes the connection with optional close details

-}
type Cmd
    = Open Url (List String)
    | Transmit String
    | Close (Maybe CloseRequest)


{-| Messages that are received from websockets

  - `Connected` when the connection succeeds, with the negotiated subprotocol
  - `Disconnected` when the connection has been terminated, with close details
  - `Text` when a new text-message has arrived on the socket
  - `TransportError` on a transport or port error

-}
type RawMsg
    = Connected (Maybe String)
    | Disconnected CloseDetails
    | Text String
    | TransportError TransportErrorDetails


{-| Typed messages received from websockets

When receiving JSON-encoded messages via websockets, this type keeps transport
errors separate from payload decoding failures.

-}
type Msg t
    = Established (Maybe String)
    | Closed CloseDetails
    | Received t
    | TransportFailure TransportErrorDetails
    | PayloadDecodeFailure String D.Error


{-| Convert a `RawMsg` into a `Msg`
-}
parseIncoming : D.Decoder t -> RawMsg -> Msg t
parseIncoming decoder rawMsg =
    case rawMsg of
        Connected protocol ->
            Established protocol

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
        Open url protocols ->
            ( "open"
            , E.object
                [ ( "url", E.string url )
                , ( "protocols", E.list E.string protocols )
                ]
            )

        Transmit data ->
            ( "transmit", E.string data )

        Close closeRequest ->
            let
                ( code, reason ) =
                    case closeRequest of
                        Just request ->
                            ( E.int request.code, E.string request.reason )

                        Nothing ->
                            ( E.null, E.null )
            in
            ( "close"
            , E.object
                [ ( "code", code )
                , ( "reason", reason )
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
decodeWsMsg : ( String, String, E.Value ) -> ( Handle, RawMsg )
decodeWsMsg ( handleValue, kind, data ) =
    ( Handle handleValue
    , case kind of
        "connected" ->
            decodeHelper (D.nullable D.string) Connected data

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
port wsCmd : CommandPort msg


{-| Websocket incoming port.
-}
port wsMsg : EventPort msg



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
