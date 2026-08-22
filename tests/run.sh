#!/bin/bash
# Everything, in the order that fails fastest. Run it before committing.
set -uo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
echo "Building tests…"
swiftc Sources/*.swift tests/main.swift -o build/tests || exit 1

echo "Unit tests:"
./build/tests || exit 1

echo "Hook tests:"
bash tests/hooks.sh || exit 1

echo
echo "All green."
