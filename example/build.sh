#!/bin/sh
# Build the WebSocket example from the local package sources.
set -eu

cd "$(dirname "$0")"
exec elm make --output=app.js src/Main.elm
