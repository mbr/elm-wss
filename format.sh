#!/bin/sh
set -eu

cd "$(dirname "$0")"

case "${1:-}" in
    "")
        nixfmt flake.nix
        elm-format --yes src example/src/Main.elm example/src/WebsocketPorts.elm
        ;;
    --check)
        nixfmt --check flake.nix
        elm-format --validate src example/src/Main.elm example/src/WebsocketPorts.elm
        ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac
