#!/usr/bin/env bash
# Run a command against one of the local gtk builds instead of the Homebrew one.
#
#   ./run.sh vanilla ~/Documents/tmp/pve-spice.sh 108    # unpatched
#   ./run.sh patched ~/Documents/tmp/pve-spice.sh 108    # patched
#
# NOTE: this deliberately does NOT just export DYLD_LIBRARY_PATH. macOS strips
# every DYLD_* variable when it exec's a SIP-protected binary, and that includes
# /bin/bash and /usr/bin/env -- so the moment the chain passes through any shell
# script's shebang, the override silently vanishes and you transparently get the
# *installed* gtk instead. That failure is invisible: the program runs fine, it
# is just testing the wrong library.
#
# Instead we put a `remote-viewer` shim first on PATH. PATH is not stripped, so
# it survives any number of intervening scripts, and the shim re-applies
# DYLD_LIBRARY_PATH immediately before exec'ing the real (unrestricted) binary.
set -euo pipefail
which=$1
shift
BASE="$(cd "$(dirname "$0")" && pwd)"
LIB="${BASE}/${which}/lib"
[[ -d "${LIB}" ]] || {
  echo "no such build: ${LIB} (run ./build.sh first)" >&2
  exit 1
}

REAL="$(command -v remote-viewer)"
SHIM="${BASE}/${which}/shim"
mkdir -p "${SHIM}"
cat >"${SHIM}/remote-viewer" <<SHIMEOF
#!/bin/bash
export DYLD_LIBRARY_PATH="${LIB}"
export XDG_DATA_DIRS="/opt/homebrew/share:/usr/local/share:/usr/share"
# DYLD_PRINT_LIBRARIES cannot be passed in from outside either -- it is a
# DYLD_* var and gets stripped the same way. Set it here, opt-in, so you can
# confirm which gtk is really being loaded.
[ -n "\${RUNSH_PRINT_LIBS:-}" ] && export DYLD_PRINT_LIBRARIES=1
exec "${REAL}" "\$@"
SHIMEOF
chmod +x "${SHIM}/remote-viewer"

# Two mechanisms, because neither covers every case on its own:
#
#  1. DYLD_LIBRARY_PATH, for binaries this script exec's directly (e.g. the
#     unit tests in ../). Lost the moment a shell script's shebang intervenes.
#  2. the PATH shim above, for `remote-viewer` reached through any number of
#     scripts. PATH is not stripped, so this survives where (1) does not.
#
# A binary other than remote-viewer, invoked from inside a script, is covered by
# neither -- it would silently get the installed gtk. Invoke such binaries
# directly from run.sh.
export DYLD_LIBRARY_PATH="${LIB}"
export XDG_DATA_DIRS="/opt/homebrew/share:/usr/local/share:/usr/share"
export PATH="${SHIM}:${PATH}"

# ./run.sh <variant> --check  -> confirm the swap actually took effect.
if [[ "${1:-}" = "--check" ]]
then
  # No pipe into grep -m1 here: it closes early, remote-viewer takes SIGPIPE,
  # and pipefail would turn that into a spurious failure.
  tmp=$(mktemp)
  RUNSH_PRINT_LIBS=1 remote-viewer --version >"${tmp}" 2>&1 || true
  got=$(grep -m1 "libgtk-3.0.dylib" "${tmp}" | sed 's/.*> //')
  rm -f "${tmp}"
  echo "expected: ${LIB}/libgtk-3.0.dylib"
  echo "actual:   ${got}"
  case "${got}" in
    "${LIB}/"*) echo "OK - ${which} gtk is in use" ;;
    *)
      echo "BROKEN - the override is not taking effect"
      exit 1
      ;;
  esac
  exit 0
fi

echo "remote-viewer will use gtk from: ${LIB}" >&2
exec "$@"
