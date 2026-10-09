#!/bin/sh
# Check formatting, API documentation, connection behavior, and the example.
set -eu

cd "$(dirname "$0")"
./format.sh --check
mkdir -p elm-stuff
elm make --docs=elm-stuff/docs.json
elm-test
./example/build.sh
