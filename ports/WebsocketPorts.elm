port module WebsocketPorts exposing (wsCmd, wsMsg)

{-| Ports used by `WebsocketSimple`.
-}

import WebsocketSimple exposing (CommandPort, EventPort)


{-| Send commands to the WebSocket runtime.
-}
port wsCmd : CommandPort msg


{-| Receive events from the WebSocket runtime.
-}
port wsMsg : EventPort msg
