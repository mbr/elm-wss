# elm-wss: Simple websockets for elm

This is a simple implementation of websockets for elm, relying on the `port` mechanism available in elm `0.19` (which no longer has an official websocket module). It aims to be readable and easy to understand.

# Usage

There is no integration with elm-packages, the easiest way to use this package is to either copy the two files into your source dir or link them using a git submodule:

`elm-websockets.js` should be sourced by your `index.html`, either or after loading the elm source. Once the elm app has been loaded, call `ElmSockets.init_app(app)` on your elm application `app` to initialize the ports.

`WebsocketSimple.elm` is a single port module that handles sending and receiving websocket messages via ports. Calling `WebsocketSimple.send` sends commands to the websockets handler outside of elm.

Each websocket namespaced by a handle (a `String`), somewhat similar to a file socket in systems programming. Handles are created by the elm application.
  
Basic usage is as follows:

  1. Create (or hardcode) a handle.
  2. Subscribe to message using the `subscribe` function.
  3. Using `send`, send the `Open` command.
