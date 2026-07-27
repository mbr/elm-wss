# Example

Start a local echo server:

```sh
websocat -E --text ws-l:127.0.0.1:8765 mirror:
```

Run `./build.sh` from this directory, then open `index.html`. Override the endpoint with a query parameter such as `index.html?url=ws://127.0.0.1:9000`.
