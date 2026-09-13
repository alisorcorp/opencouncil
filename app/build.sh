#!/bin/sh
# Builds Council.app. Uses Xcode-beta through DEVELOPER_DIR when it is installed, so xcode-select does not
# need changing, and whatever xcode-select points at when it is not.
#   ./build.sh            # generate project (if needed) and build Debug
#   ./build.sh test       # run CouncilCore tests + app tests
#   ./build.sh run        # build and open the app
#   ./build.sh snapshot <session-dir> <out.png> [w h] [--dark] [--live] [--terminal <member>] [--chrome]
#                         # render the window to a PNG offscreen (no screen recording permission needed)
#                         # --chrome gives the window its titlebar, so the toolbar is in the picture
#   ./build.sh drive <chat-dir> "<message>" [--timeout s] [--to a,b] [--resume]
#                         # start the chat's members in hidden terminals, paste the message, report hooks/posts
#                         # COUNCIL_FAKE_MEMBERS=1 runs app/Tools/fake-member.py instead of the real CLIs
#   ./build.sh render-replay <chat-dir> <output-dir> [--stress] [--live]
#                         # Release UI replay on a private copy. --live adds the scripted stand-ins,
#                         # so terminals and the ticker are present. No model calls either way.
#   ./build.sh install [dir]
#                         # build Release and put Council.app in /Applications (or `dir`)
#   ./build.sh ask <run-dir> [--timeout s] [--retry-moderator]
#                         # run a verdict: ask every member, collect the answers, then the moderator
#                         # --retry-moderator re-runs only the synthesis for a run whose moderator gave up
set -e
cd "$(dirname "$0")"
# Xcode 27 beta when it is installed, so xcode-select does not need changing; otherwise whatever is selected,
# which is what a clone on a machine with released Xcode has.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
# Signing is per-machine, so it is not in the repo: `signing.local` (untracked, see signing.local.example)
# names a certificate and team, and without one the build is ad-hoc — which works for anyone who clones this,
# it just cannot keep the permissions macOS grants the app from one build to the next.
[ -f signing.local ] && . ./signing.local
export COUNCIL_CODE_SIGN_IDENTITY="${COUNCIL_CODE_SIGN_IDENTITY:--}"
export COUNCIL_DEVELOPMENT_TEAM="${COUNCIL_DEVELOPMENT_TEAM:-}"
xcodegen generate --quiet   # always: the project must list every source file, and new files appear often
DERIVED="${DERIVED:-$PWD/.build/DerivedData}"
case "${1:-build}" in
  build) xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet ;;
  test)
    # The core suite's own exit status decides, never the filter: piping into grep would hand the pipeline
    # grep's status, and grep matches a failure just as happily as it matches "Executed".
    CORELOG="${TMPDIR:-/tmp}/council-core-tests.$$.log"
    if (cd CouncilCore && swift test 2>&1) > "$CORELOG"; then
      grep -E "error|Executed|failed" "$CORELOG" || true
      rm -f "$CORELOG"
    else
      grep -E "error|Executed|failed" "$CORELOG" || tail -20 "$CORELOG"
      rm -f "$CORELOG"
      echo "CouncilCore tests failed" >&2
      exit 1
    fi
    # Same treatment for the app suite, and without -quiet: quiet hides the tally, so a scheme that stopped
    # running CouncilAppTests at all would report success in exactly the same words as a suite that passed.
    APPLOG="${TMPDIR:-/tmp}/council-app-tests.$$.log"
    if xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" \
         -skipPackagePluginValidation test > "$APPLOG" 2>&1; then
      grep -E "Executed [0-9]+ test" "$APPLOG" | tail -1 || echo "no app tests ran" >&2
      rm -f "$APPLOG"
    else
      grep -E "error:|Executed [0-9]+ test|failed" "$APPLOG" | tail -20 || tail -20 "$APPLOG"
      rm -f "$APPLOG"
      echo "Council app tests failed" >&2
      exit 1
    fi ;;
  run)
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    open "$DERIVED/Build/Products/Debug/Council.app" ;;
  install)
    # A Release build, installed where a Mac app belongs. It signs with the same identity as every other
    # build, so whatever the installed copy is granted — Documents access, notifications — it keeps when a
    # later install replaces it. `ditto` rather than `cp -R`: it preserves the extended attributes a bundle's
    # signature is checked against.
    shift
    DEST_DIR="${1:-/Applications}"
    case "$DEST_DIR" in /*) ;; *) echo "install: the destination must be an absolute path" >&2; exit 2 ;; esac
    [ -d "$DEST_DIR" ] || { echo "install: $DEST_DIR is not a directory" >&2; exit 2; }
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Release -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    BUILT="$DERIVED/Build/Products/Release/Council.app"
    codesign --verify --strict "$BUILT" || { echo "install: the build does not verify; nothing was installed" >&2; exit 1; }
    DEST="$DEST_DIR/Council.app"
    if [ -e "$DEST" ]; then
      # Replacing a bundle out from under a running copy leaves it half-there and crashing.
      pgrep -f "^$DEST/Contents/MacOS/Council" >/dev/null && { echo "install: $DEST is running — quit it first" >&2; exit 1; }
      rm -rf "$DEST"
    fi
    ditto "$BUILT" "$DEST"
    codesign --verify --strict "$DEST" || { echo "install: the installed copy does not verify" >&2; exit 1; }
    echo "installed $DEST"
    codesign -dv "$DEST" 2>&1 | grep -E 'Authority=Apple Development|TeamIdentifier' ;;
  snapshot)
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    shift
    "$DERIVED/Build/Products/Debug/Council.app/Contents/MacOS/Council" --snapshot "$@" ;;
  drive)
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    shift
    "$DERIVED/Build/Products/Debug/Council.app/Contents/MacOS/Council" --drive "$@" ;;
  render-replay)
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Release -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    shift
    "$DERIVED/Build/Products/Release/Council.app/Contents/MacOS/Council" --render-replay "$@" ;;
  ask)
    xcodebuild -project Council.xcodeproj -scheme Council -configuration Debug -derivedDataPath "$DERIVED" -skipPackagePluginValidation build -quiet
    shift
    "$DERIVED/Build/Products/Debug/Council.app/Contents/MacOS/Council" --ask "$@" ;;
  *) echo "usage: $0 [build|test|run|install|snapshot|drive|render-replay|ask]"; exit 2 ;;
esac
