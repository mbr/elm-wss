#!/bin/sh
set -eu

cd "$(dirname "$0")"

case "${1:-}" in
    "")
        nixfmt flake.nix
        elm-format --yes elm ports example/src/Main.elm
        ;;
    --check)
        nixfmt --check flake.nix
        elm-format --validate elm ports example/src/Main.elm
        ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac
