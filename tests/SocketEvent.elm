module SocketEvent exposing (at)

{-| Constructs managed socket input with explicit native timestamps.
-}

import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection


{-| Supplies a receipt time without reading a clock or opening a socket.
-}
at : Float -> Ws.Handle -> Ws.RawMsg -> Connection.Msg
at timestamp handle message =
    Connection.receive { timestamp = timestamp, handle = handle, message = message }
