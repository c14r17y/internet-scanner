#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/bin"
MCGRAB_SRC="$ROOT/deps/mcgrab"
ZGRAB2_SRC="$ROOT/deps/zgrab2"

if [[ -z "$ROOT" || "$ROOT" == "/" ]]; then
    echo "Invalid ROOT: $ROOT"
    exit 1
fi

rm -rf -- "$BIN"
mkdir -p -- "$BIN"

echo "[*] Building mcgrab..."
cd "$MCGRAB_SRC"
go mod tidy
GOOS=linux GOARCH=amd64 go build -o "$BIN/mcgraber" .

echo "[*] Building zgrab2..."
cd "$ZGRAB2_SRC"
go build -o "$BIN/zgrab2" ./cmd/zgrab2

chmod +x "$BIN/mcgraber" "$BIN/zgrab2"

echo "[*] Build complete:"
ls -lh "$BIN"
