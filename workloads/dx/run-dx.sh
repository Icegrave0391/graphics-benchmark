#!/usr/bin/env bash
#
# run-dx.sh — run a Windows DirectX .exe through Proton (DXVK/VKD3D -> Vulkan).
#
# Thin wrapper over umu-run that pins the wine prefix, picks the API backend
# (D3D11 via DXVK / D3D12 via VKD3D-Proton — both auto-selected by the app's own
# API), and optionally wraps the run in MangoHud so frame metrics use the same
# capture layer as the GL/Vulkan workloads (design §3 methodology).
#
# Usage:
#   run-dx.sh [--mangohud] [--] <App.exe> [app args...]
#
# Examples:
#   run-dx.sh ../l1-gpu-bound/GravityMark-win/GravityMark.exe -d3d11 -benchmark 1 -close 1
#   run-dx.sh --mangohud SomeBench.exe
#
# Env overrides:
#   DX_PREFIX     wine prefix (default workloads/dx/prefix)
#   PROTONPATH    specific Proton (default: UMU-Proton = official Proton)
#   GAMEID        umu game id for protonfixes (default umu-default)
#   MANGOHUD_OUT  MangoHud CSV output dir (default workloads/dx/captures)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DX_PREFIX="${DX_PREFIX:-$LAYER_DIR/prefix}"
GAMEID="${GAMEID:-umu-default}"
STORE="${STORE:-none}"
MANGOHUD_OUT="${MANGOHUD_OUT:-$LAYER_DIR/captures}"

USE_MANGOHUD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mangohud) USE_MANGOHUD=1; shift ;;
    --) shift; break ;;
    -*) break ;;   # unknown leading flag -> treat rest as exe + args
    *) break ;;
  esac
done

EXE="${1:-}"
[[ -z "$EXE" ]] && { log_err "usage: run-dx.sh [--mangohud] <App.exe> [args...]"; exit 1; }
[[ -f "$EXE" ]] || { log_err "exe not found: $EXE"; exit 1; }
shift
EXE_ABS="$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")"

need_cmd umu-run

log_info "==> DX run via Proton"
log_info "    exe     : $EXE_ABS"
log_info "    prefix  : $DX_PREFIX"
log_info "    proton  : ${PROTONPATH:-UMU-Proton (official)}"
log_info "    mangohud: $([[ $USE_MANGOHUD == 1 ]] && echo on || echo off)"

mkdir -p "$DX_PREFIX"

run_umu() {
  WINEPREFIX="$DX_PREFIX" GAMEID="$GAMEID" STORE="$STORE" \
    ${PROTONPATH:+PROTONPATH="$PROTONPATH"} \
    umu-run "$EXE_ABS" "$@"
}

if [[ "$USE_MANGOHUD" == "1" ]]; then
  need_cmd mangohud
  mkdir -p "$MANGOHUD_OUT"
  # MangoHud logs per-frame frametimes to CSV; load it into the Proton/Vulkan app.
  export MANGOHUD=1
  export MANGOHUD_CONFIG="output_folder=${MANGOHUD_OUT},fps_only=0,no_display=1"
  log_info "    capture : $MANGOHUD_OUT (MangoHud CSV)"
  # umu/Proton run inside the Steam Runtime container; MANGOHUD env is forwarded.
  run_umu "$@"
else
  run_umu "$@"
fi
