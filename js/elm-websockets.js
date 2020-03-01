// Copyright (c) 2020 Marc Brinkmann

// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

ElmWebsockets = (function() {
  var pub = {};

  pub.initApp = function(app) {
    if (app.ports && app.ports.wsCmd) {
      app.webSockets = {};

      app.ports.wsCmd.subscribe(function(msg) {
        var handle = msg[0];
        var cmd = msg[1];
        var data = msg[2];

        switch (cmd) {
          case "open":
            if (app.webSockets.hasOwnProperty(handle)) {
              // Tear down existing handler.
              var ws = app.webSockets[handle];
              ws.onmessage = null;
              ws.onclose = null;
              ws.onerror = null;
              ws.onopen = null;
              ws.close();
            }

            // TODO: Catch illegal string error.
            // TODO: Catch security exception error.
            var ws = new WebSocket(data.url, data.protocol);
            ws.onclose = function(closeEvent) {
              // TODO: code, reason, wasClean
              app.ports.wsMsg.send(["closed", null]);
            };
            ws.onerror = function(errorEvent) {
              app.ports.wsMsg.send(["error", errorEvent.message]);
            };
            ws.onmessage = function(messageEvent) {
              // We need to differentiate different types of data here.
              // TODO: origin, lastEventId, source, ports?
              // console.log("INCOMING", messageEvent);
              switch (typeof messageEvent.data) {
                case "string":
                  app.ports.wsMsg.send(["message", messageEvent.data]);
                  break;
                default:
                  app.ports.wsMsg.send([
                    "error",
                    "Received non-string message of type " +
                      typeof messageEvent.data +
                      ", which cannot be handled"
                  ]);
                  break;
              }
            };
            ws.onopen = function(event) {
              app.ports.wsMsg.send(["open", null]);
            };
            break;
          case "close":
            if (app.webSocekts.hasOwnProperty(handle)) {
              app.webSockets[handle].close(data.code, data.reason);
              delete app.webSockets[handle];
            }
            // If not openend, we simply ignore it.
            break;
          default:
            console.log("Received unknown command from elm:", cmd);
        }
      });
    } else {
      // This happens if the app is not using any ports.
      console.log("websocket port is not defined in Elm app");
    }
  };

  return pub;
})();
