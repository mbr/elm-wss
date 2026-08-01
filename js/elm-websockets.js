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
      app.webSockets = new Map();

      function emit(message) {
        if (app.ports.wsMsg) {
          app.ports.wsMsg.send(message);
        }
      }

      function emitError(handle, kind, message) {
        emit([handle, "error", { kind: kind, message: message }]);
      }

      function reportError(handle, operation, error) {
        var message = "websocket " + operation + " failed";
        if (error && typeof error.message === "string" && error.message) {
          message += ": " + error.message;
        } else if (typeof error === "string" && error) {
          message += ": " + error;
        }
        emitError(handle, operation, message);
      }

      function bytesToByteString(bytes) {
        var chunks = [];
        var chunkSize = 32768;
        for (var offset = 0; offset < bytes.length; offset += chunkSize) {
          chunks.push(
            String.fromCharCode.apply(
              null,
              bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length))
            )
          );
        }
        return chunks.join("");
      }

      function byteStringToBytes(byteString) {
        var bytes = new Uint8Array(byteString.length);
        for (var index = 0; index < byteString.length; index++) {
          bytes[index] = byteString.charCodeAt(index);
        }
        return bytes;
      }

      function readBlob(blob, onLoad, onError) {
        if (
          typeof FileReader === "function" &&
          typeof FileReader.prototype.readAsBinaryString === "function"
        ) {
          var reader = new FileReader();
          reader.onload = function() {
            if (typeof reader.result === "string") {
              onLoad(reader.result);
            } else {
              onError(new Error("binary websocket message reader returned no string"));
            }
          };
          reader.onerror = function() {
            onError(reader.error || new Error("binary websocket message read failed"));
          };
          reader.onabort = function() {
            onError(new Error("binary websocket message read was aborted"));
          };
          try {
            reader.readAsBinaryString(blob);
          } catch (error) {
            onError(error);
          }
          return;
        }

        if (typeof blob.arrayBuffer !== "function") {
          onError(new Error("browser cannot read binary websocket messages"));
          return;
        }

        blob.arrayBuffer().then(
          function(buffer) {
            var byteString;
            try {
              byteString = bytesToByteString(new Uint8Array(buffer));
            } catch (error) {
              onError(error);
              return;
            }
            onLoad(byteString);
          },
          onError
        );
      }

      app.ports.wsCmd.subscribe(function(msg) {
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
              var ws = data.protocols.length
                ? new WebSocket(data.url, data.protocols)
                : new WebSocket(data.url);
              ws.binaryType = "blob";
            } catch (error) {
              reportError(handle, "construction", error);
              break;
            }
            var entry = {
              initiatedLocally: false,
              socket: ws
            };
            app.webSockets.set(handle, entry);
            ws.onclose = function(closeEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              app.webSockets.delete(handle);
              emit([
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
              reportError(handle, "transport", errorEvent);
            };
            ws.onmessage = function(messageEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }

              if (typeof messageEvent.data === "string") {
                emit([handle, "message", messageEvent.data]);
              } else if (
                typeof Blob !== "undefined" &&
                messageEvent.data instanceof Blob
              ) {
                readBlob(
                  messageEvent.data,
                  function(byteString) {
                    if (app.webSockets.get(handle) === entry) {
                      emit([handle, "binary", byteString]);
                    }
                  },
                  function(error) {
                    if (app.webSockets.get(handle) === entry) {
                      reportError(handle, "transport", error);
                    }
                  }
                );
              } else {
                emitError(
                  handle,
                  "unsupported-data",
                  "received unsupported websocket message data"
                );
              }
            };
            ws.onopen = function() {
              if (
                app.webSockets.get(handle) !== entry ||
                ws.readyState !== WebSocket.OPEN
              ) {
                return;
              }

              emit([handle, "connected", ws.protocol || null]);
            };
            break;

          case "transmit":
          case "transmit-binary":
            var entry = app.webSockets.get(handle);
            if (entry && entry.socket.readyState === WebSocket.OPEN) {
              try {
                entry.socket.send(
                  cmd === "transmit-binary" ? byteStringToBytes(data) : data
                );
              } catch (error) {
                reportError(handle, "send", error);
              }
            } else {
              emitError(
                handle,
                "send-rejection",
                "cannot transmit unless websocket is open"
              );
            }
            break;

          case "close":
            if (app.webSockets.has(handle)) {
              var entry = app.webSockets.get(handle);
              try {
                if (data.code === null) {
                  entry.socket.close();
                } else {
                  entry.socket.close(data.code, data.reason);
                }
                entry.initiatedLocally = true;
              } catch (error) {
                reportError(handle, "close", error);
              }
            }
            // Closing an absent socket is a no-op.
            break;

          default:
            throw new Error("unknown websocket command: " + cmd);
        }
      });
    }
  };

  return pub;
})();
