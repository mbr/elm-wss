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


module WebsocketSimple exposing
    ( CommandPort, EventPort
    , Cmd(..), CloseRequest, open, close, send, sendWithHandle
    , Handle, handle, handleToString
    , RawMsg(..), CloseDetails, TransportErrorKind(..), TransportErrorDetails, subscribe, subscribeWithHandle, errorKindToString, errorToString
    , Msg(..), subscribeMsg, subscribeMsgWithHandle, transmitMsg, transmitMsgWithHandle, parseIncoming
    )

{-| A small, typed WebSocket client for Elm with a compact, auditable JavaScript runtime. It supports multiple connections, lifecycle events, and text or JSON messages.


# Installation

Install the Elm package:

```sh
elm install mbr/elm-wss
```

Elm packages cannot declare ports. Make `Main.elm` a `port module`, or use another application-owned `port module`, then add these declarations:

    import WebsocketSimple exposing (CommandPort, EventPort)

    port wsCmd : CommandPort msg

    port wsMsg : EventPort msg

The JavaScript runtime expects the exact port names `wsCmd` and `wsMsg`.

Copy [`js/elm-websockets.js`](https://github.com/mbr/elm-wss/blob/1.0.0/js/elm-websockets.js) into the browser assets. Load the runtime and compiled Elm application, initialize Elm, and then initialize the runtime:

```html
<script src="elm-websockets.js"></script>
<script src="app.js"></script>
<script>
var app = Elm.Main.init({
  node: document.getElementById("elm")
});
ElmWebsockets.initApp(app);
</script>
```

The JavaScript initialization is a no-op when the application does not contain the command port, so it can remain in the bootstrap while WebSocket code is temporarily unused.


# Ports

Pass the application-owned ports described by these aliases to commands and subscriptions.

@docs CommandPort, EventPort


# Basic usage

Subscribe to events before opening a connection, and wait for `Connected` before transmitting.

    import WebsocketPorts as Ports
    import WebsocketSimple as WebSocket

    type Msg
        = WebSocketEvent WebSocket.RawMsg

    init : () -> ( List String, Cmd Msg )
    init _ =
        ( [], WebSocket.open Ports.wsCmd "ws://127.0.0.1:8765" )

    update : Msg -> List String -> ( List String, Cmd Msg )
    update msg model =
        case msg of
            WebSocketEvent (WebSocket.Connected _) ->
                ( model, WebSocket.send Ports.wsCmd (WebSocket.Transmit "hello") )

            WebSocketEvent (WebSocket.Text value) ->
                ( value :: model, WebSocket.close Ports.wsCmd )

            WebSocketEvent (WebSocket.Disconnected _) ->
                ( model, Cmd.none )

            WebSocketEvent (WebSocket.TransportError error) ->
                ( WebSocket.errorToString error :: model, Cmd.none )

    subscriptions : List String -> Sub Msg
    subscriptions _ =
        Sub.map WebSocketEvent (WebSocket.subscribe Ports.wsMsg)


# Commands

`send` and its convenience functions use an implicit `"default"` handle. Use `sendWithHandle` for multiple connections.

@docs Cmd, CloseRequest, open, close, send, sendWithHandle


# Handles

Each connection is identified by an opaque handle encoded as a string at the port boundary.

    chat : WebSocket.Handle
    chat =
        WebSocket.handle "chat"

    alerts : WebSocket.Handle
    alerts =
        WebSocket.handle "alerts"

    openConnections : Cmd msg
    openConnections =
        Cmd.batch
            [ WebSocket.sendWithHandle Ports.wsCmd chat (WebSocket.Open chatUrl [])
            , WebSocket.sendWithHandle Ports.wsCmd alerts (WebSocket.Open alertsUrl [])
            ]

@docs Handle, handle, handleToString


# Events

`subscribe` discards handle information. Use `subscribeWithHandle` to distinguish events from multiple connections.

    type Msg
        = WebSocketEvent ( WebSocket.Handle, WebSocket.RawMsg )

    subscriptions : model -> Sub Msg
    subscriptions _ =
        Sub.map WebSocketEvent (WebSocket.subscribeWithHandle Ports.wsMsg)

@docs RawMsg, CloseDetails, TransportErrorKind, TransportErrorDetails, subscribe, subscribeWithHandle, errorKindToString, errorToString


# JSON

Regular subscriptions expose incoming text frames as `Text String`. Typed subscriptions decode text frames while keeping transport errors separate from payload decoding failures.

    import Json.Decode as Decode

    type alias Payload =
        { message : String }

    payloadDecoder : Decode.Decoder Payload
    payloadDecoder =
        Decode.map Payload (Decode.field "message" Decode.string)

    type Msg
        = WebSocketMessage (WebSocket.Msg Payload)

    subscriptions : model -> Sub Msg
    subscriptions _ =
        WebSocket.subscribeMsg Ports.wsMsg payloadDecoder WebSocketMessage

@docs Msg, subscribeMsg, subscribeMsgWithHandle, transmitMsg, transmitMsgWithHandle, parseIncoming

-}

import Json.Decode as D
import Json.Encode as E
import Platform.Cmd


{-| Type of an application-owned port that sends encoded commands to the JavaScript runtime.
-}
type alias CommandPort msg =
    ( String, String, E.Value ) -> Platform.Cmd.Cmd msg


{-| Type of an application-owned port that receives encoded events from the JavaScript runtime.
-}
type alias EventPort msg =
    (( String, String, E.Value ) -> msg) -> Sub msg


{-| Identifies a particular WebSocket connection.
-}
type Handle
    = Handle String


{-| Construct a WebSocket handle from its port-boundary representation.
-}
handle : String -> Handle
handle =
    Handle


{-| Return a WebSocket handle's string representation.
-}
handleToString : Handle -> String
handleToString (Handle value) =
    value


{-| WebSocket endpoint URL.
-}
type alias Url =
    String


{-| Details supplied when a WebSocket closes.

The event may arrive even when the connection never opened. `initiatedLocally` records whether this client successfully requested closure.

-}
type alias CloseDetails =
    { code : Int
    , reason : String
    , wasClean : Bool
    , initiatedLocally : Bool
    }


{-| Describes an application-requested close.

Use an empty reason to send only the explicit close code.

-}
type alias CloseRequest =
    { code : Int
    , reason : String
    }


{-| Categorizes a WebSocket transport error.
-}
type TransportErrorKind
    = ConstructionFailure
    | SendFailure
    | CloseFailure
    | BrowserFailure
    | SendRejection
    | UnsupportedData
    | PortDecodingFailure


{-| Describes a categorized WebSocket transport error.
-}
type alias TransportErrorDetails =
    { kind : TransportErrorKind
    , message : String
    }


{-| Render a transport error as a readable string containing its category and message.
-}
errorToString : TransportErrorDetails -> String
errorToString error =
    "[" ++ errorKindToString error.kind ++ "] " ++ error.message


{-| Render a transport error category as a string.
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


{-| Subscribe to raw events paired with their originating handles.
-}
subscribeWithHandle : EventPort ( Handle, RawMsg ) -> Sub ( Handle, RawMsg )
subscribeWithHandle eventPort =
    eventPort decodeWsMsg


{-| Subscribe to raw events from the implicit default connection.

This discards the originating handle from every event.

-}
subscribe : EventPort RawMsg -> Sub RawMsg
subscribe eventPort =
    eventPort (decodeWsMsg >> Tuple.second)


{-| Subscribe to typed JSON events while discarding handle information.
-}
subscribeMsg : EventPort msg -> D.Decoder t -> (Msg t -> msg) -> Sub msg
subscribeMsg eventPort dec wrap =
    eventPort (decodeWsMsg >> Tuple.second >> parseIncoming dec >> wrap)


{-| Subscribe to typed JSON events paired with their originating handles.
-}
subscribeMsgWithHandle : EventPort msg -> D.Decoder t -> (( Handle, Msg t ) -> msg) -> Sub msg
subscribeMsgWithHandle eventPort dec wrap =
    eventPort
        (\value ->
            let
                ( socketHandle, rawMsg ) =
                    decodeWsMsg value
            in
            wrap ( socketHandle, parseIncoming dec rawMsg )
        )


{-| Send a command to the connection identified by a handle.
-}
sendWithHandle : CommandPort msg -> Handle -> Cmd -> Platform.Cmd.Cmd msg
sendWithHandle commandPort (Handle socketHandle) cmd =
    let
        ( cmdString, data ) =
            encodeWsCmd cmd
    in
    commandPort ( socketHandle, cmdString, data )


{-| Send a command to the implicit `"default"` connection.
-}
send : CommandPort msg -> Cmd -> Platform.Cmd.Cmd msg
send commandPort =
    sendWithHandle commandPort (Handle "default")


{-| Open the implicit default connection without requesting a subprotocol.
-}
open : CommandPort msg -> String -> Platform.Cmd.Cmd msg
open commandPort url =
    send commandPort <| Open url []


{-| Close the implicit default connection with the browser's default status.
-}
close : CommandPort msg -> Platform.Cmd.Cmd msg
close commandPort =
    send commandPort <| Close Nothing


{-| Encode a value as JSON and transmit it through the implicit default connection.
-}
transmitMsg : CommandPort msg -> (t -> E.Value) -> t -> Platform.Cmd.Cmd msg
transmitMsg commandPort =
    transmitMsgWithHandle commandPort (Handle "default")


{-| Encode a value as JSON and transmit it through the connection identified by a handle.
-}
transmitMsgWithHandle : CommandPort msg -> Handle -> (t -> E.Value) -> t -> Platform.Cmd.Cmd msg
transmitMsgWithHandle commandPort socketHandle enc msg =
    enc msg |> E.encode 0 |> Transmit |> sendWithHandle commandPort socketHandle


{-| Command sent to a WebSocket connection.

  - `Open` opens the URL with an ordered list of requested subprotocols. An empty list requests none.
  - `Transmit` sends a text frame. A rejected transmission produces a `TransportError`; an accepted transmission produces no acknowledgement.
  - `Close Nothing` preserves the browser's default close behavior. `Close (Just request)` sends the supplied code and reason unchanged, leaving validation to the browser.

-}
type Cmd
    = Open Url (List String)
    | Transmit String
    | Close (Maybe CloseRequest)


{-| Raw event received from a WebSocket connection.

  - `Connected` means the connection can transmit and contains the negotiated subprotocol, if any.
  - `Disconnected` contains the browser's close details and may occur without a preceding `Connected` event.
  - `Text` contains a received text frame. Binary frames are unsupported and produce a transport error.
  - `TransportError` describes a construction, send, close, browser, unsupported-data, or port-decoding failure.

-}
type RawMsg
    = Connected (Maybe String)
    | Disconnected CloseDetails
    | Text String
    | TransportError TransportErrorDetails


{-| Typed event received from a WebSocket connection carrying JSON text frames.

Transport failures remain separate from payload decoding failures. `PayloadDecodeFailure` retains both the original text and the `Json.Decode.Error`.

-}
type Msg t
    = Established (Maybe String)
    | Closed CloseDetails
    | Received t
    | TransportFailure TransportErrorDetails
    | PayloadDecodeFailure String D.Error


{-| Convert a raw event into a typed JSON event.
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


{-| Encode a command for the JavaScript runtime.
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


{-| Decode an event payload, converting failures into transport errors.
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


{-| Decode a transport error category.
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


{-| Decode transport error details.
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


{-| Decode WebSocket close details.
-}
decodeCloseDetails : D.Decoder CloseDetails
decodeCloseDetails =
    D.map4 CloseDetails
        (D.field "code" D.int)
        (D.field "reason" D.string)
        (D.field "wasClean" D.bool)
        (D.field "initiatedLocally" D.bool)


{-| Decode an event from the JavaScript runtime.
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


{-| Resolve a result by mapping its error value.
-}
extract : (e -> a) -> Result e a -> a
extract f x =
    case x of
        Ok a ->
            a

        Err e ->
            f e
