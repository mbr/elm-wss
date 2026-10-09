#!/bin/sh
# Build both WebSocket examples from the local package sources.
set -eu

cd "$(dirname "$0")"
exec elm make --output=app.js src/Main.elm src/Managed.elm
