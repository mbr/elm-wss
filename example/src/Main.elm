port module Main exposing (..)

import Browser
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E
import Json.Encode.Extra as Ex
import WebsocketSimple as WSS


type alias WebSocketHandle =
    String


type alias Url =
    String


type alias Model =
    Int


type Message
    = WebsocketReceived (WSS.Msg String)


wsHandle =
    "default"


init : () -> ( Model, Cmd msg )
init _ =
    ( 0, WSS.send (WSS.Open "wss://echo.websocket.org/" Nothing) wsHandle )


view : Model -> Browser.Document msg
view _ =
    Browser.Document "Hello!" [ text "Hi!" ]


update : Message -> Model -> ( Model, Cmd msg )
update msg model =
    case msg of
        WebsocketReceived WSS.Established ->
            Debug.log ("YAY" ++ Debug.toString msg) ( model, WSS.send (WSS.Transmit "HELLO?") wsHandle )

        WebsocketReceived wsmsg ->
            Debug.log (Debug.toString msg) ( model, Cmd.none )


subscriptions : Model -> Sub Message
subscriptions _ =
    Sub.map WebsocketReceived <| WSS.subscribe D.string


main =
    Browser.document
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
