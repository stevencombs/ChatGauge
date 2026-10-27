#!/usr/bin/env bash
# Live UI self-test: runs the built app against a mock Ollama with a throwaway home folder
# (CFFIXED_USER_HOME), sends one prompt from the real popover, and writes report.txt + PNGs.
# Touches nothing outside .selftest/. Usage: scripts/ui-selftest.sh [path/to/ChatGauge binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/ChatGauge}"
ROOT="$PWD/.selftest"; rm -rf "$ROOT"; mkdir -p "$ROOT/home/Library/Application Support/ChatGauge" "$ROOT/models" "$ROOT/out"
PORT=11599
cat > "$ROOT/home/Library/Application Support/ChatGauge/settings.json" <<JSON
{"app":"ChatGauge","schema":1,"settings":{"serverURL":"http://127.0.0.1:$PORT","modelsLocation":"local",
 "modelsPath":"$ROOT/models","checkForUpdates":false,"voiceEnabled":false,"keepLoaded":true,"hotKey":{"enabled":false,"keyCode":8,"carbonModifiers":6144}}}
JSON
python3 scripts/dev/mock_ollama.py $PORT 2>"$ROOT/mock.log" & MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
sleep 0.5
CFFIXED_USER_HOME="$ROOT/home" HOME="$ROOT/home" CHATGAUGE_UI_SELFTEST="$ROOT/out" perl -e 'alarm 40; exec @ARGV' "$BIN" >"$ROOT/app.log" 2>&1 || true
cat "$ROOT/out/report.txt" 2>/dev/null || { echo "no report"; tail -20 "$ROOT/app.log"; }
