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


port module WebsocketSimple exposing (Cmd(..), Msg(..), send, sendWithHandle, subscribe, subscribeWithHandle)

{-| The simple websockets module.

To get start, ensure the runtime is installed (`elm-websockets.js`) and
called. Subscribe to websocket messages through `subscribe`, send them using
`send`. That's it.

-}

import Json.Decode as D
import Json.Encode as E
import Platform.Cmd
import Result.Extra


{-| A handle identifies a particular websocket
-}
type alias WebSocketHandle =
    String


{-| Websocket URL to connect to (`ws://..` or `ws:///...`)
-}
type alias Url =
    String


{-| Subscribe for incoming messages tagged with handler

Yields tuples of `(handler, msg)`

-}
subscribeWithHandle : Sub ( WebSocketHandle, Msg )
subscribeWithHandle =
    wsMsg decodeWsMsg


{-| Subscribe for incoming messages, discarding handler information
-}
subscribe : Sub Msg
subscribe =
    Sub.map Tuple.second subscribeWithHandle


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

  - `Established` on connection establishment
  - `Closed` when the connection has been closed
  - `Text` when a new text-message has arrived on the socket
  - `Error` on any kind of internal or external error

-}
type Msg
    = Established
    | Closed
    | Text String
    | Error String


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


{-| Decode a JSON string, yield an `Error` on failure
-}
decodeHelper : D.Decoder v -> (v -> Msg) -> D.Value -> Msg
decodeHelper decoder map value =
    D.decodeValue decoder value
        |> Result.map map
        |> extract
            (\e -> Error ("decoding error in incoming channel message: " ++ D.errorToString e))


{-| Decode an incoming websocket message from javascript
-}
decodeWsMsg : ( WebSocketHandle, String, E.Value ) -> ( WebSocketHandle, Msg )
decodeWsMsg ( handle, kind, data ) =
    ( handle
    , case kind of
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
