#!/bin/sh
# Creates the `council` wrapper in ~/.local/bin pointing at this folder. Run again if you move the folder.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 not found"; exit 1; }
"$PY" - <<'PYEOF' || exit 1
import sys
if sys.version_info < (3, 11):
    sys.exit(f"python3 is {sys.version.split()[0]}; council needs 3.11+ (tomllib)")
try:
    import prompt_toolkit  # noqa: F401
except ImportError:
    sys.exit("prompt_toolkit is missing: pip3 install prompt_toolkit")
PYEOF
mkdir -p "$BIN"
printf '#!/bin/sh\nexec "%s" "%s/council.py" "$@"\n' "$PY" "$HERE" > "$BIN/council"
chmod +x "$BIN/council"
echo "installed $BIN/council -> $HERE/council.py"
for tool in herdr claude codex pi; do
  command -v "$tool" >/dev/null 2>&1 && echo "  found $tool" || echo "  MISSING $tool (needed for council to work)"
done
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH; add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to your shell profile" ;;
esac
echo "next: council members"
