#!/usr/bin/env bash
#
# run.sh — run Windows GravityMark through Proton (DXVK/VKD3D -> Vulkan).
#
# Wrapper over the shared workloads/proton/run.sh that points at the extracted
# Windows GravityMark and selects the DirectX backend:
#   --d3d11  -> DXVK
#   --d3d12  -> VKD3D-Proton
#
# On venus-linux the translated Vulkan runs on the host through Venus.
#
# Usage:
#   run.sh [--d3d11|--d3d12] [--mangohud] [-- <extra GravityMark args>]
#
# Env overrides:
#   GM_ASTEROIDS  fixed object count for comparability (default 200000)
#   GM_WIDTH/GM_HEIGHT  window size (default 1280x720)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../lib" && pwd)/common.sh"

refuse_root

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROTON_RUN="$(cd "$LAYER_DIR/../../proton" && pwd)/run.sh"
[[ -x "$PROTON_RUN" ]] || { log_err "shared Proton runner missing: $PROTON_RUN (run workloads/proton/install.sh)"; exit 1; }

GM_EXE="$(find "$LAYER_DIR/GravityMark-win" -type f -iname 'GravityMark.exe' 2>/dev/null | head -n1)"
[[ -z "$GM_EXE" ]] && { log_err "GravityMark.exe not found; run $LAYER_DIR/install.sh first"; exit 1; }

API_FLAG="-d3d11"
MANGOHUD_ARGS=()
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --d3d11) API_FLAG="-d3d11"; shift ;;
    --d3d12) API_FLAG="-d3d12"; shift ;;
    --mangohud) MANGOHUD_ARGS=(--mangohud); shift ;;
    --) shift; EXTRA=( "$@" ); break ;;
    *) EXTRA+=( "$1" ); shift ;;
  esac
done

GM_ASTEROIDS="${GM_ASTEROIDS:-200000}"
GM_WIDTH="${GM_WIDTH:-1280}"
GM_HEIGHT="${GM_HEIGHT:-720}"

log_info "==> GravityMark DX: $API_FLAG (asteroids=$GM_ASTEROIDS, ${GM_WIDTH}x${GM_HEIGHT})"

exec "$PROTON_RUN" "${MANGOHUD_ARGS[@]}" -- "$GM_EXE" \
  "$API_FLAG" -fullscreen 0 -width "$GM_WIDTH" -height "$GM_HEIGHT" \
  -asteroids "$GM_ASTEROIDS" -benchmark 1 -close 1 "${EXTRA[@]}"
