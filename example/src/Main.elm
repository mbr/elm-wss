module Main exposing (..)

{-| Example application for websockets
-}

import Browser
import Html exposing (Html, div, text)
import WebsocketSimple as Ws


{-| Model, stores event log

Anything command sent or event received is stored for this demo.

-}
type alias Model =
    List Event


{-| An event log entry
-}
type Event
    = Sent Ws.Cmd
    | WebsocketEvent Ws.RawMsg


{-| The sole message we can receive is a websocket one
-}
type Message
    = WebsocketReceived Ws.RawMsg


{-| Initialize application

Will connect to an example echo websocket immediately

-}
init : () -> ( Model, Cmd Message )
init _ =
    let
        cmd =
            Ws.Open "wss://echo.websocket.org/" Nothing
    in
    ( [ Sent cmd ], Ws.send cmd )


{-| Render event log as HTML
-}
view : Model -> Browser.Document msg
view model =
    Browser.Document "Websockets example"
        [ div [] (List.map viewEvent model)
        ]


{-| Render a single event log entry
-}
viewEvent : Event -> Html msg
viewEvent event =
    case event of
        Sent cmd ->
            div [] [ text <| "send -> " ++ Debug.toString cmd ]

        WebsocketEvent msg ->
            div [] [ text <| "recv <- " ++ Debug.toString msg ]


{-| Note that a specific message has been received and response, log
-}
receiveSend : Ws.RawMsg -> Ws.Cmd -> Model -> ( Model, Cmd msg )
receiveSend event cmd model =
    ( model ++ [ WebsocketEvent event, Sent cmd ], Ws.send cmd )


{-| Core update function
-}
update : Message -> Model -> ( Model, Cmd msg )
update msg model =
    case msg of
        WebsocketReceived (Ws.Established as w) ->
            receiveSend w (Ws.Transmit "Test message") model

        WebsocketReceived ((Ws.Text t) as w) ->
            receiveSend w (Ws.Close Nothing Nothing) model

        WebsocketReceived w ->
            ( model ++ [ WebsocketEvent w ], Cmd.none )


{-| Setup app subscriptions
-}
subscriptions : Model -> Sub Message
subscriptions _ =
    Sub.map WebsocketReceived <| Ws.subscribe


{-| Main entry point
-}
main =
    Browser.document
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
