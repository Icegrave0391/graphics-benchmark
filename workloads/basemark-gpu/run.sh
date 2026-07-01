#!/usr/bin/env bash
#
# run.sh — run Basemark GPU from the CLI, no GUI launcher.
#
# The Electron `basemarkgpu` app is just a front-end; the real benchmark is the
# native binary resources/binaries/BasemarkGPU_{vk,gl}, which is a normal CLI
# program taking key/value params. This wrapper calls it directly so runs are
# scriptable (the free GUI itself can't be automated — design §4).
#
# It is an ONSCREEN renderer (no headless/offscreen mode): run it from a desktop
# session (native) or with DISPLAY=:0 (guest GNOME/Xorg). Set USE_XVFB=1 to wrap
# it in a virtual X server for a truly headless host.
#
# Per design §2.1 routing: api=vulkan -> Venus path, api=gl -> VirGL path.
# Caveats (design §4/§6): AMD+RADV crashes at High/4K -> default here is medium
# 1080p; the free build uploads to the Power Board unless ResultUpload is off
# (we default it off — set BMK_UPLOAD=1 to match the GUI's mandatory upload).
#
# Usage:
#   run-basemark.sh [--api vulkan|gl] [--quality simple|medium|highend]
#                   [--res 1920x1080] [--tc bc7|astc|etc2|etc|none]
#                   [--loops N] [--gpu IDX] [--mangohud] [--] [extra K V ...]
#
# Results: JSON written under <out>/ (default workloads/.../captures/basemark);
# fields result.score / averageFPS / minFPS / maxFPS, software.api.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Find the extracted Basemark tree (install.sh puts it here).
APP_ROOT="$(find "$LAYER_DIR/BasemarkGPU" -maxdepth 2 -type d -name 'basemarkgpu-*' 2>/dev/null | head -n1)"
[[ -z "$APP_ROOT" ]] && { log_err "Basemark not found; run workloads/basemark-gpu/install.sh first"; exit 1; }

API="vulkan"
QUALITY="medium"
RES="1920x1080"
TC="bc7"
LOOPS="1"
GPU="0"
USE_MANGOHUD=0
OUT="${BMK_OUT:-$LAYER_DIR/captures/basemark}"
UPLOAD="${BMK_UPLOAD:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api)      API="$2"; shift 2 ;;
    --quality)  QUALITY="$2"; shift 2 ;;
    --res)      RES="$2"; shift 2 ;;
    --tc)       TC="$2"; shift 2 ;;
    --loops)    LOOPS="$2"; shift 2 ;;
    --gpu)      GPU="$2"; shift 2 ;;
    --mangohud) USE_MANGOHUD=1; shift ;;
    --)         shift; break ;;
    *)          break ;;
  esac
done
EXTRA=( "$@" )   # passed through verbatim as extra K V params

case "$API" in
  vulkan|vk) BIN="BasemarkGPU_vk"; API_NAME="vulkan" ;;
  gl|opengl) BIN="BasemarkGPU_gl"; API_NAME="gl" ;;
  *) log_err "--api must be vulkan or gl (got: $API)"; exit 1 ;;
esac

BIN_PATH="$APP_ROOT/resources/binaries/$BIN"
ASSET="$APP_ROOT/resources/assets/pkg"
[[ -x "$BIN_PATH" ]] || { log_err "binary missing: $BIN_PATH"; exit 1; }
[[ -d "$ASSET" ]]    || { log_err "asset pkg missing: $ASSET"; exit 1; }
mkdir -p "$OUT"

[[ -z "${DISPLAY:-}" && "${USE_XVFB:-0}" != "1" ]] && \
  log_warn "DISPLAY is unset — Basemark renders onscreen. Use a desktop session, DISPLAY=:0, or USE_XVFB=1."

UPLOAD_VAL=false; [[ "$UPLOAD" == "1" ]] && UPLOAD_VAL=true

PARAMS=(
  TestType Official
  RenderPipeline "$QUALITY"
  RenderResolution "$RES"
  TextureCompression "$TC"
  Fullscreen false
  ResultUpload "$UPLOAD_VAL"
  LoopCount "$LOOPS"
  GpuIndex "$GPU"
  AssetPath "$ASSET"
  StoragePath "$OUT"
  ProgressBar true
  "${EXTRA[@]}"
)

log_info "==> Basemark GPU (CLI)"
log_info "    api      : $API_NAME  ($BIN)"
log_info "    quality  : $QUALITY @ $RES, tc=$TC, loops=$LOOPS, gpu=$GPU"
log_info "    upload   : $UPLOAD_VAL   (free build normally forces true)"
log_info "    results  : $OUT/*.json  (result.score/averageFPS/min/maxFPS)"

# mangohud / xvfb-run wrap the binary call as needed.
if [[ "${USE_XVFB:-0}" == "1" ]]; then
  need_cmd xvfb-run
  if [[ "$USE_MANGOHUD" == "1" ]]; then need_cmd mangohud
    MANGOHUD=1 xvfb-run -a env LD_LIBRARY_PATH="$APP_ROOT" mangohud "$BIN_PATH" "${PARAMS[@]}"
  else
    xvfb-run -a env LD_LIBRARY_PATH="$APP_ROOT" "$BIN_PATH" "${PARAMS[@]}"
  fi
else
  if [[ "$USE_MANGOHUD" == "1" ]]; then need_cmd mangohud
    MANGOHUD=1 LD_LIBRARY_PATH="$APP_ROOT" mangohud "$BIN_PATH" "${PARAMS[@]}"
  else
    LD_LIBRARY_PATH="$APP_ROOT" "$BIN_PATH" "${PARAMS[@]}"
  fi
fi
RC=$?

echo
if [[ $RC -eq 0 ]]; then
  log_info "==> done. Result JSON(s):"
  find "$OUT" -name '*.json' -newermt '-2 min' 2>/dev/null | sed 's/^/    /'
  log_info "    (fields: result.score, result.averageFPS/minFPS/maxFPS, software.api)"
else
  log_err "Basemark exited with code $RC. If it crashed at startup, check DISPLAY"
  log_err "and that libssl1.1 is installed (install-basemark-gpu.sh handles it)."
fi
exit $RC
