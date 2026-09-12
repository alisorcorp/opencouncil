#!/bin/sh
# Creates the `council` wrapper in ~/.local/bin pointing at this folder. Run again if you move the folder.
#
# Only python3.11+ is required: the wrapper is how members post to a chat, so both the macOS app and the
# terminal version need it. Everything else this reports is optional, and what you need depends on which one
# you are here for. The terminal chat needs prompt_toolkit and herdr; the app needs neither.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 not found"; exit 1; }
"$PY" - <<'PYEOF' || exit 1
import sys
if sys.version_info < (3, 11):
    sys.exit(f"python3 is {sys.version.split()[0]}; council needs 3.11+ (tomllib)")
PYEOF
mkdir -p "$BIN"
printf '#!/bin/sh\nexec "%s" "%s/council.py" "$@"\n' "$PY" "$HERE" > "$BIN/council"
chmod +x "$BIN/council"
echo "installed $BIN/council -> $HERE/council.py"

# The members themselves. Which ones you want is up to council.toml; kimi runs only in the macOS app,
# because herdr has no kimi agent kind.
echo "members on your PATH:"
found=0
for tool in claude codex kimi pi; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  $tool"
    found=$((found + 1))
  fi
done
[ "$found" -gt 0 ] || echo "  none yet. Install at least one of claude, codex, kimi or pi and log into it."

# Optional, and only for the terminal chat. Said as notes rather than errors so that installing for the app
# does not look like a failure.
"$PY" -c 'import prompt_toolkit' 2>/dev/null \
  || echo "note: prompt_toolkit is missing, so 'council session' and 'council chat' cannot run (pip3 install prompt_toolkit). The macOS app does not use it."
command -v herdr >/dev/null 2>&1 \
  || echo "note: herdr is missing, so 'council session' and 'council chat' cannot run. The macOS app does not use it."

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH; add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to your shell profile" ;;
esac
echo "next: 'council members' checks that each configured member is reachable, and 'app/build.sh install' builds the macOS app."
