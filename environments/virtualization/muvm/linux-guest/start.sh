#!/usr/bin/env bash
#
# start.sh — muvm-linux: run a command inside a libkrun/muvm microVM that
# reaches the host AMD GPU via a drm NATIVE CONTEXT (lowest transport overhead).
#
# muvm is NOT QEMU and does NOT boot the shared qcow2 image. It launches a
# lightweight microVM (libkrun) that shares the host filesystem and runs a
# command directly; the GPU is exposed through virtio-gpu's drm native context
# (amdgpu UAPI), not Venus/VirGL. See docs/benchmark-design.md §1.
#
# Because there is no separate guest userspace, the *host's* Mesa/Vulkan stack
# (installed by host/scripts/00-base-kvm.sh) is what runs — so benchmark tools
# must be available on the host PATH.
#
# Build muvm + libkrun + native-context virglrenderer first:
#   host/scripts: 00-base-kvm.sh -> 30-venus.sh -> 40-muvm.sh   (QEMU/05 unused)
#
# Usage:
#   ./start.sh                       # interactive shell inside the microVM
#   ./start.sh -- vulkaninfo --summary
#   ./start.sh -- glmark2 --off-screen
set -euo pipefail

# Repo paths + logging (reuse the shared helpers' logging only).
_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_DIR/../../../.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_err()  { echo -e "${RED}$1${NC}" >&2; }

MUVM="${MUVM:-/usr/local/bin/muvm}"
[[ -x "$MUVM" ]] || MUVM="$(command -v muvm || true)"

# --- preconditions -----------------------------------------------------------
if [[ -z "$MUVM" || ! -x "$MUVM" ]]; then
  log_err "muvm not found. Build it: host/scripts/40-muvm.sh (after 00 and 30-venus.sh)."
  exit 1
fi

# kernel >= 6.13 for the virtio-gpu drm-native-context params.
KREL="$(uname -r)"; KMAJ="${KREL%%.*}"; KMIN="$(echo "$KREL" | cut -d. -f2)"
if (( KMAJ < 6 || (KMAJ == 6 && KMIN < 13) )); then
  log_warn "kernel $KREL < 6.13 — drm native context may be unavailable; install HWE/mainline."
fi

# native-context virglrenderer (built by 30-venus.sh with amdgpu-experimental).
if ! ls /usr/local/lib*/libvirglrenderer.so* >/dev/null 2>&1; then
  log_warn "No /usr/local virglrenderer found — 40-muvm needs the native-context build (30-venus.sh)."
fi

# --- the command to run inside the microVM -----------------------------------
# Everything after a leading '--' is the guest command; default: a login shell.
if [[ "${1:-}" == "--" ]]; then shift; fi
CMD=( "$@" )
if (( ${#CMD[@]} == 0 )); then
  CMD=( "${SHELL:-/bin/bash}" )
fi

log_info "==> muvm-linux (libkrun + drm native context)  [guest: linux/host-shared]"
log_info "    GPU path : virtio-gpu drm native context -> host Mesa (RADV/radeonsi) -> amdgpu"
log_info "    running  : ${CMD[*]}"
log_info "    verify   : run 'vulkaninfo --summary | grep deviceName' inside (expect AMD, not llvmpipe)"

exec "$MUVM" -- "${CMD[@]}"
