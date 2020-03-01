port module Main exposing (..)

import Browser
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E
import WebsocketSimple as WSS


type alias WebSocketHandle =
    String


type alias Url =
    String


type alias Model =
    Int


type Message
    = WebsocketReceived WSS.Msg


init : () -> ( Model, Cmd msg )
init _ =
    ( 0, WSS.send (WSS.Open "wss://echo.websocket.org/" Nothing) )


view : Model -> Browser.Document msg
view _ =
    Browser.Document "Hello!" [ text "Hi!" ]


update : Message -> Model -> ( Model, Cmd msg )
update msg model =
    case msg of
        WebsocketReceived WSS.Established ->
            Debug.log (Debug.toString msg) ( model, WSS.send (WSS.Transmit "HELLO?") )

        WebsocketReceived wsmsg ->
            Debug.log (Debug.toString msg) ( model, Cmd.none )


subscriptions : Model -> Sub Message
subscriptions _ =
    Sub.map WebsocketReceived <| WSS.subscribe


main =
    Browser.document
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
