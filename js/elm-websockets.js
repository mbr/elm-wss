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

      /** Sends an event record to Elm. */
      function emit(event) {
        if (app.ports.wsMsg) {
          app.ports.wsMsg.send(event);
        }
      }

      /** Describes a failed transport operation. */
      function errorPayload(operation, error) {
        var message = "websocket " + operation + " failed";
        if (error && typeof error.message === "string" && error.message) {
          message += ": " + error.message;
        } else if (typeof error === "string" && error) {
          message += ": " + error;
        }
        return { kind: operation, message: message };
      }

      /** Reports failures without a native browser event. */
      function reportError(handle, operation, error) {
        emit({
          timestamp: performance.now(),
          handle: handle,
          kind: "error",
          payload: errorPayload(operation, error)
        });
      }

      /** Delivers an event and retires closed sockets. */
      function deliverIncoming(entry, event) {
        if (event.kind === "disconnected") {
          app.webSockets.delete(entry.handle);
        }
        emit(event);
      }

      /** Reserves an ordered slot for asynchronous decoding. */
      function reserveIncoming(entry) {
        var pending = { event: null };
        entry.incomingEvents.push(pending);
        return pending;
      }

      /** Delivers ready events while the socket is still current. */
      function drainIncoming(entry) {
        while (
          app.webSockets.get(entry.handle) === entry &&
          entry.nextIncomingEvent < entry.incomingEvents.length
        ) {
          var pending = entry.incomingEvents[entry.nextIncomingEvent];
          if (pending.event === null) {
            return;
          }

          entry.nextIncomingEvent++;
          deliverIncoming(entry, pending.event);
        }

        entry.incomingEvents = [];
        entry.nextIncomingEvent = 0;
      }

      /** Completes a reserved event once decoding finishes. */
      function completeIncoming(entry, pending, event) {
        if (pending.event === null) {
          pending.event = event;
          drainIncoming(entry);
        }
      }

      /** Preserves event order around pending binary decoding. */
      function queueIncoming(entry, event) {
        if (entry.incomingEvents.length === 0) {
          deliverIncoming(entry, event);
          return;
        }

        entry.incomingEvents.push({ event: event });
        drainIncoming(entry);
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
          var reader;
          try {
            reader = new FileReader();
          } catch (error) {
            onError(error);
            return;
          }
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

        var bufferPromise;
        try {
          bufferPromise = blob.arrayBuffer();
        } catch (error) {
          onError(error);
          return;
        }
        bufferPromise.then(
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
              handle: handle,
              incomingEvents: [],
              initiatedLocally: false,
              nextIncomingEvent: 0,
              socket: ws
            };
            app.webSockets.set(handle, entry);
            ws.onclose = function(closeEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              queueIncoming(entry, {
                timestamp: closeEvent.timeStamp,
                handle: handle,
                kind: "disconnected",
                payload: {
                  code:
                    typeof closeEvent.code === "number"
                      ? closeEvent.code
                      : 1006,
                  initiatedLocally: entry.initiatedLocally,
                  reason:
                    typeof closeEvent.reason === "string"
                      ? closeEvent.reason
                      : "",
                  wasClean: Boolean(closeEvent.wasClean)
                }
              });
            };
            ws.onerror = function(errorEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }
              queueIncoming(entry, {
                timestamp: errorEvent.timeStamp,
                handle: handle,
                kind: "error",
                payload: errorPayload("transport", errorEvent)
              });
            };
            ws.onmessage = function(messageEvent) {
              if (app.webSockets.get(handle) !== entry) {
                return;
              }

              if (typeof messageEvent.data === "string") {
                queueIncoming(entry, {
                  timestamp: messageEvent.timeStamp,
                  handle: handle,
                  kind: "message",
                  payload: messageEvent.data
                });
              } else if (
                typeof Blob !== "undefined" &&
                messageEvent.data instanceof Blob
              ) {
                var timestamp = messageEvent.timeStamp;
                var pending = reserveIncoming(entry);
                readBlob(
                  messageEvent.data,
                  function(byteString) {
                    completeIncoming(entry, pending, {
                      timestamp: timestamp,
                      handle: handle,
                      kind: "binary",
                      payload: byteString
                    });
                  },
                  function(error) {
                    completeIncoming(entry, pending, {
                      timestamp: timestamp,
                      handle: handle,
                      kind: "error",
                      payload: errorPayload("transport", error)
                    });
                  }
                );
              } else {
                queueIncoming(entry, {
                  timestamp: messageEvent.timeStamp,
                  handle: handle,
                  kind: "error",
                  payload: {
                    kind: "unsupported-data",
                    message: "received unsupported websocket message data"
                  }
                });
              }
            };
            ws.onopen = function(openEvent) {
              if (
                app.webSockets.get(handle) !== entry ||
                ws.readyState !== WebSocket.OPEN
              ) {
                return;
              }

              emit({
                timestamp: openEvent.timeStamp,
                handle: handle,
                kind: "connected",
                payload: ws.protocol || null
              });
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
              emit({
                timestamp: performance.now(),
                handle: handle,
                kind: "error",
                payload: {
                  kind: "send-rejection",
                  message: "cannot transmit unless websocket is open"
                }
              });
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
