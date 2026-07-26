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

  pub.initApp = function(app, enableDebug) {
    if (app.ports && app.ports.wsCmd) {
      app.webSockets = new Map();

      function reportError(handle, operation, error) {
        var message = "websocket " + operation + " failed";
        if (error && typeof error.message === "string" && error.message) {
          message += ": " + error.message;
        } else if (typeof error === "string" && error) {
          message += ": " + error;
        }
        app.ports.wsMsg.send([handle, "error", message]);
      }

      app.ports.wsCmd.subscribe(function(msg) {
        var debug = enableDebug ? console.log : function() {};

        var handle = msg[0];
        var cmd = msg[1];
        var data = msg[2];

        switch (cmd) {
          case "open":
            if (app.webSockets.has(handle)) {
              // Tear down existing handler.
              var entry = app.webSockets.get(handle);
              try {
                entry.socket.close();
                entry.initiatedLocally = true;
              } catch (error) {
                reportError(handle, "close", error);
                break;
              }
            }

            try {
              var ws = new WebSocket(data.url, data.protocol || []);
            } catch (error) {
              reportError(handle, "construction", error);
              break;
            }
            var entry = {
              initiatedLocally: false,
              socket: ws
            };
            app.webSockets.set(handle, entry);
            if (debug) {
              debug(handle, "created new websocket", ws);
            }
            ws.onclose = function(closeEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              app.webSockets.delete(handle);
              debug(handle, "[onclose]", closeEvent);
              app.ports.wsMsg.send([
                handle,
                "disconnected",
                {
                  code: typeof closeEvent.code === "number" ? closeEvent.code : 1006,
                  initiatedLocally: entry.initiatedLocally,
                  reason: typeof closeEvent.reason === "string" ? closeEvent.reason : "",
                  wasClean: Boolean(closeEvent.wasClean)
                }
              ]);
            };
            ws.onerror = function(errorEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              debug(handle, "[onerror]", errorEvent);
              reportError(handle, "transport", errorEvent);
            };
            ws.onmessage = function(messageEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              debug(handle, "[onmessage]", messageEvent);

              // We need to differentiate different types of data here.
              // TODO: origin, lastEventId, source, ports?
              // console.log("INCOMING", messageEvent);
              switch (typeof messageEvent.data) {
                case "string":
                  app.ports.wsMsg.send([handle, "message", messageEvent.data]);
                  break;
                default:
                  app.ports.wsMsg.send([
                    handle,
                    "error",
                    "received unsupported binary websocket message"
                  ]);
                  break;
              }
            };
            ws.onopen = function(event) {
              if (
                app.webSockets.get(handle) !== entry ||
                ws.readyState !== WebSocket.OPEN
              ) {
                return;
              }
              debug(handle, "[onopen]", event);

              app.ports.wsMsg.send([handle, "connected", null]);
            };
            break;

          case "transmit":
            debug(handle, "[send]", data);

            var entry = app.webSockets.get(handle);
            if (entry && entry.socket.readyState === WebSocket.OPEN) {
              try {
                entry.socket.send(data);
              } catch (error) {
                reportError(handle, "send", error);
              }
            } else {
              app.ports.wsMsg.send([handle, "error", "cannot transmit unless websocket is open"])
            }


            break;

          case "close":
            debug(handle, "[close]", app.webSockets.has(handle), data);
            if (app.webSockets.has(handle)) {
              var entry = app.webSockets.get(handle);
              try {
                entry.socket.close(data.code || 1000, data.reason || "");
                entry.initiatedLocally = true;
              } catch (error) {
                reportError(handle, "close", error);
              }
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
