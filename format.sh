#!/bin/sh
set -eu

cd "$(dirname "$0")"

case "${1:-}" in
    "")
        nixfmt flake.nix
        elm-format --yes src tests example/src
        ;;
    --check)
        nixfmt --check flake.nix
        elm-format --validate src tests example/src
        ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac
