#!/usr/bin/env bash
#
# run.sh — run a Windows DirectX .exe through Proton (DXVK/VKD3D -> Vulkan).
#
# Thin wrapper over umu-run that pins the shared wine prefix and optionally wraps
# the run in MangoHud so frame metrics use the same capture layer as the native
# Vulkan/GL workloads. The Windows app selects its own API (D3D11 -> DXVK,
# D3D12 -> VKD3D-Proton); both translate to Vulkan.
#
# The per-workload dx/run.sh scripts call this with the right .exe and args.
#
# Usage:
#   run.sh [--mangohud] [--] <App.exe> [app args...]
#
# Env overrides:
#   PROTON_PREFIX wine prefix (default workloads/proton/prefix)
#   PROTONPATH    specific Proton (default: UMU-Proton = official Proton)
#   GAMEID        umu game id for protonfixes (default umu-default)
#   MANGOHUD_OUT  MangoHud CSV output dir (default workloads/proton/captures)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROTON_PREFIX="${PROTON_PREFIX:-$LAYER_DIR/prefix}"
GAMEID="${GAMEID:-umu-default}"
STORE="${STORE:-none}"
MANGOHUD_OUT="${MANGOHUD_OUT:-$LAYER_DIR/captures}"

USE_MANGOHUD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mangohud) USE_MANGOHUD=1; shift ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

EXE="${1:-}"
[[ -z "$EXE" ]] && { log_err "usage: run.sh [--mangohud] <App.exe> [args...]"; exit 1; }
[[ -f "$EXE" ]] || { log_err "exe not found: $EXE"; exit 1; }
shift
EXE_ABS="$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")"

need_cmd umu-run

log_info "==> DX run via Proton"
log_info "    exe     : $EXE_ABS"
log_info "    prefix  : $PROTON_PREFIX"
DEFAULT_PROTONPATH="${XDG_DATA_HOME:-$HOME/.local/share}/umu/compatibilitytools/UMU-Proton"
log_info "    proton  : ${PROTONPATH:-$DEFAULT_PROTONPATH}"
log_info "    mangohud: $([[ $USE_MANGOHUD == 1 ]] && echo on || echo off)"

# When launched from an SSH/remote terminal into a local GNOME Wayland session,
# DISPLAY may be set manually (e.g. DISPLAY=:0) but XAUTHORITY is often missing.
# Xwayland then rejects the app with "Authorization required". Infer the common
# GNOME Xwayland auth file so Proton/DXVK can create the benchmark window.
if [[ -n "${DISPLAY:-}" && -z "${XAUTHORITY:-}" ]]; then
  for auth in "${XDG_RUNTIME_DIR:-/run/user/$UID}"/.mutter-Xwaylandauth.* "$HOME/.Xauthority"; do
    if [[ -r "$auth" ]]; then
      export XAUTHORITY="$auth"
      log_info "    xauth   : $XAUTHORITY"
      break
    fi
  done
fi

mkdir -p "$PROTON_PREFIX"

run_umu() {
  local proton_env="${PROTONPATH:-$DEFAULT_PROTONPATH}"
  [[ -f "$proton_env/toolmanifest.vdf" ]] || {
    log_err "Proton runtime not found or incomplete: $proton_env"
    log_err "Run workloads/proton/install.sh first."
    return 1
  }
  # Many benchmark bundles (GravityMark in particular) expect their process cwd
  # to be the executable directory so relative assets like ../data.zip resolve.
  # umu-run accepts an absolute exe path but does not change cwd for us.
  (
    cd "$(dirname "$EXE_ABS")"
    env \
      WINEPREFIX="$PROTON_PREFIX" \
      GAMEID="$GAMEID" \
      STORE="$STORE" \
      PROTONPATH="$proton_env" \
      umu-run "$EXE_ABS" "$@"
  )
}

if [[ "$USE_MANGOHUD" == "1" ]]; then
  need_cmd mangohud
  mkdir -p "$MANGOHUD_OUT"
  export MANGOHUD=1
  export MANGOHUD_CONFIG="output_folder=${MANGOHUD_OUT},fps_only=0,no_display=1"
  log_info "    capture : $MANGOHUD_OUT (MangoHud CSV)"
  run_umu "$@"
else
  run_umu "$@"
fi
