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
# Fake Homebrew + Ollama for the setup guide: "brew install" only drops stub scripts into $ROOT/bin, and the stub
# `ollama serve` is the same mock on the port it's given. Nothing real is installed or downloaded.
MOCK_PY="$PWD/scripts/dev/mock_ollama.py"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/.fake-ollama" <<SH
#!/bin/sh
case "\$1" in
  --version|-v) echo "ollama version is 0.40.11" ;;
  serve) H="\${OLLAMA_HOST:-127.0.0.1:11434}"; exec /usr/bin/python3 "$MOCK_PY" "\${H##*:}" ;;
  *) echo "fake ollama: \$*" ;;
esac
SH
cat > "$ROOT/bin/brew" <<SH
#!/bin/sh
B="$ROOT/bin"
case "\$1" in
  --version) echo "Homebrew 4.6.9" ;;
  list) shift; [ "\$1" = "--versions" ] && shift
        for f in "\$@"; do [ -f "\$B/.installed-\$f" ] && echo "\$f \$(cat "\$B/.installed-\$f")"; done; exit 0 ;;
  install) f="\$2"
        echo "==> Fetching \$f"; sleep 0.3; echo "==> Downloading https://ghcr.io/v2/homebrew/core/\$f (fake)"; sleep 0.3
        echo "==> Pouring \$f--1.0.arm64_sequoia.bottle.tar.gz"; sleep 0.2
        case "\$f" in
          ollama) cp "\$B/.fake-ollama" "\$B/ollama"; echo 0.40.11 > "\$B/.installed-ollama" ;;
          whisper-cpp) printf '#!/bin/sh\necho fake whisper-cli\n' > "\$B/whisper-cli"; echo 1.8.2 > "\$B/.installed-whisper-cpp" ;;
          ffmpeg) printf '#!/bin/sh\necho "ffmpeg version 8.0 fake"\n' > "\$B/ffmpeg"; echo 8.0 > "\$B/.installed-ffmpeg" ;;
        esac
        chmod +x "\$B"/* 2>/dev/null; echo "🍺  \$f was installed (fake)" ;;
  *) echo "fake brew: \$*" ;;
esac
SH
chmod +x "$ROOT/bin/brew" "$ROOT/bin/.fake-ollama"
export CHATGAUGE_SETUP_BIN="$ROOT/bin" CHATGAUGE_SETUP_WHISPER_BASE="http://127.0.0.1:$PORT/whisper"
python3 scripts/dev/mock_ollama.py $PORT 2>"$ROOT/mock.log" & MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
sleep 0.5
CFFIXED_USER_HOME="$ROOT/home" HOME="$ROOT/home" CHATGAUGE_UI_SELFTEST="$ROOT/out" perl -e 'alarm 420; exec @ARGV' "$BIN" >"$ROOT/app.log" 2>&1 || true
cat "$ROOT/out/report.txt" 2>/dev/null || { echo "no report"; tail -20 "$ROOT/app.log"; }
