module Managed exposing (main)

{-| An echo client that keeps reconnecting and lets the application replace a socket.
-}

import Again.Remote as Remote
import Browser
import Html exposing (button, div, text)
import Html.Attributes exposing (disabled)
import Html.Events exposing (onClick)
import WebsocketPorts as Ports
import WebsocketSimple as Ws
import WebsocketSimple.Connection as Connection


{-| The maintained connection and most recent echo.
-}
type alias Model =
    { connection : Connection.Model
    , message : String
    }


{-| Connection events and application operations.
-}
type Msg
    = ConnectionMsg Connection.Msg
    | SendMessage
    | MissedHeartbeat


{-| Begin maintaining the requested endpoint.
-}
init : String -> ( Model, Cmd Msg )
init url =
    let
        ( connection, actions ) =
            Connection.init (Connection.new url)
    in
    ( { connection = connection, message = "" }
    , Connection.perform Ports.wsCmd ConnectionMsg actions
    )


{-| Apply connection transitions and handle the application's text protocol.
-}
update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ConnectionMsg event ->
            let
                ( connection, actions, incoming ) =
                    Connection.update event model.connection

                message =
                    case incoming of
                        Just (Connection.Text body) ->
                            body

                        Just (Connection.Error error) ->
                            Ws.errorToString error

                        _ ->
                            model.message
            in
            ( { model | connection = connection, message = message }
            , Connection.perform Ports.wsCmd ConnectionMsg actions
            )

        SendMessage ->
            ( model
            , case Connection.get model.connection of
                Just handle ->
                    Ws.sendWithHandle Ports.wsCmd handle (Ws.Transmit "Hello from the managed connection")

                Nothing ->
                    Cmd.none
            )

        MissedHeartbeat ->
            let
                ( connection, actions ) =
                    Connection.fail "Application heartbeat missing" model.connection
            in
            ( { model | connection = connection }
            , Connection.perform Ports.wsCmd ConnectionMsg actions
            )


{-| Show connection progress and controls for exercising reconnection.
-}
view : Model -> Browser.Document Msg
view model =
    let
        status =
            case Connection.state model.connection of
                Remote.Attempting ->
                    "Connecting"

                Remote.WaitingForRetry _ ->
                    "Waiting to reconnect"

                Remote.Retrying _ ->
                    "Reconnecting"

                Remote.Successful _ ->
                    "Connected"

                Remote.Failed _ ->
                    "Failed"
    in
    Browser.Document "Managed WebSocket example"
        [ div [] [ text status ]
        , button [ onClick SendMessage, disabled (Connection.get model.connection == Nothing) ] [ text "Send message" ]
        , button [ onClick MissedHeartbeat ] [ text "Simulate missed heartbeat" ]
        , div [] [ text model.message ]
        ]


{-| Run the managed example with the endpoint supplied as a flag.
-}
main : Program String Model Msg
main =
    Browser.document
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Connection.subscribe Ports.wsMsg |> Sub.map ConnectionMsg
        }
