# Example

Start a local echo server:

```sh
websocat -E --text ws-l:127.0.0.1:8765 mirror:
```

Run `./build.sh` from this directory, then open `index.html` for the low-level client or `managed.html` for the maintained connection. Override the endpoint with a query parameter such as `managed.html?url=ws://127.0.0.1:9000`.

The managed example reconnects when the server disappears and provides a button to simulate an application-detected missing heartbeat. Stop and restart the echo server to try its retry behavior.
