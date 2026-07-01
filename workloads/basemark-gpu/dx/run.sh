#!/usr/bin/env bash
#
# run.sh — run Windows Basemark GPU through Proton (VKD3D-Proton -> Vulkan).
#
# Wrapper over the shared workloads/proton/run.sh that locates the Basemark GPU
# exe installed in the Proton prefix and launches it. Basemark's free build is
# GUI-driven; select DirectX 12 in the launcher to exercise the VKD3D-Proton
# path. On venus-linux the translated Vulkan runs on the host through Venus.
#
# Usage:
#   run.sh [--mangohud] [-- <extra args>]
#
# Env overrides:
#   PROTON_PREFIX  wine prefix (default workloads/proton/prefix)
#   BMK_EXE        explicit path to the installed BasemarkGPU exe

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../lib" && pwd)/common.sh"

refuse_root

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROTON_DIR="$(cd "$LAYER_DIR/../../proton" && pwd)"
PROTON_RUN="$PROTON_DIR/run.sh"
PROTON_PREFIX="${PROTON_PREFIX:-$PROTON_DIR/prefix}"
[[ -x "$PROTON_RUN" ]] || { log_err "shared Proton runner missing: $PROTON_RUN (run workloads/proton/install.sh)"; exit 1; }

BMK_EXE="${BMK_EXE:-}"
if [[ -z "$BMK_EXE" ]]; then
  BMK_EXE="$(find "$PROTON_PREFIX/drive_c" -type f -iname 'basemark*gpu*.exe' 2>/dev/null | grep -vi 'unins' | head -n1)"
fi
[[ -z "$BMK_EXE" ]] && { log_err "Basemark exe not found in prefix; run $LAYER_DIR/install.sh first (or set BMK_EXE)"; exit 1; }

MANGOHUD_ARGS=()
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mangohud) MANGOHUD_ARGS=(--mangohud); shift ;;
    --) shift; EXTRA=( "$@" ); break ;;
    *) EXTRA+=( "$1" ); shift ;;
  esac
done

log_info "==> Basemark GPU DX (D3D12 -> VKD3D-Proton)"
exec "$PROTON_RUN" "${MANGOHUD_ARGS[@]}" -- "$BMK_EXE" "${EXTRA[@]}"
