#!/usr/bin/env bash
#
# install.sh — GravityMark workload on Linux.
#
# GravityMark is kept as a standalone workload (not part of L1/L2/L3 layering).
# It has a full CLI (-benchmark / -close / per-frame stats / asteroids / API),
# which makes it useful for smoke-testing Vulkan/OpenGL paths.
#
# Distribution: Tellusim ships Linux as a Makeself .run self-installer. Running
# it normally pops an interactive license + browser flow; we extract it with
# --noexec --target instead, getting the plain payload directory (bin/ + the
# run_*.sh launchers) for headless CLI automation. No system packages are
# installed and nothing is written outside workloads/ — so the SAME script works
# unchanged on native-linux and inside the guest VM.
#
# Run as your normal user (NOT root) so the extracted tree stays user-owned.
#
# Env overrides:
#   GM_VERSION   GravityMark version to fetch (default 1.89)
#   GM_URL       full .run URL (default derived from GM_VERSION)
#   WL_CACHE     download cache dir (default workloads/.cache)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

GM_VERSION="${GM_VERSION:-1.89}"
GM_RUN="GravityMark_${GM_VERSION}.run"
GM_URL="${GM_URL:-https://tellusim.com/download/${GM_RUN}}"

# Layer dir for this tool; the extracted payload lives here (git-ignored).
LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$LAYER_DIR/GravityMark"
RUN_CACHE="$WL_CACHE/$GM_RUN"

log_info "==> Installing workload: GravityMark ${GM_VERSION}"

# Runtime needs Vulkan/GL/X libs to actually launch; on a freshly-built guest or
# a minimal native host these may be missing. Pull the same userspace the guest
# cloud-init installs (harmless / no-op if already present).
apt_install \
  libvulkan1 vulkan-tools \
  libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgles2 \
  libx11-6 libxext6 libxi6 libxrandr2 \
  curl

download "$GM_URL" "$RUN_CACHE"
makeself_extract "$RUN_CACHE" "$INSTALL_DIR"

# Payload sits at the archive root: bin/GravityMark.x64 + libTellusim_x64.so, and
# convenience launchers run_*.sh that cd into bin/ and set the API flag.
BIN_DIR="$(find "$INSTALL_DIR" -maxdepth 2 -type d -name bin 2>/dev/null | head -n1)"
GM_BIN="$(find "$INSTALL_DIR" -maxdepth 2 -type f -name 'GravityMark*.x64' 2>/dev/null | head -n1)"

if [[ -z "$BIN_DIR" || -z "$GM_BIN" ]]; then
  log_err "Extraction looked wrong: no bin/ or GravityMark.x64 under $INSTALL_DIR"
  log_err "Inspect: ls -R '$INSTALL_DIR'"
  exit 1
fi

log_info "==> GravityMark installed:"
log_info "    binary   : $GM_BIN"
log_info "    libs     : $BIN_DIR  (LD_LIBRARY_PATH, or just use the run_*.sh)"

cat <<EOF

Done. GravityMark ${GM_VERSION} is extracted under:
    $INSTALL_DIR

This script is identical for native-linux and the Linux guest (same Ubuntu
24.04 / Mesa stack). It only writes inside workloads/, so push the repo into
the guest and run it there too.

Run from the CLI. The API flag selects the path under test (design §2.1).
GravityMark uses -vulkan / -opengl (NOT -api), -benchmark 1 / -close 1, and can
dump per-frame times. Easiest is the bundled launchers (they cd into bin/ and
set LD_LIBRARY_PATH for you):

    # Vulkan (Venus path), windowed, fixed asteroid count, auto-close, dump times:
    $INSTALL_DIR/run_windowed_vk.sh  -asteroids 200000 -benchmark 1 -close 1 \\
        -times $INSTALL_DIR/vk_times.txt

    # OpenGL (VirGL path):
    $INSTALL_DIR/run_windowed_gl.sh  -asteroids 200000 -benchmark 1 -close 1 \\
        -times $INSTALL_DIR/gl_times.txt

Or invoke the binary directly:
    export LD_LIBRARY_PATH="$BIN_DIR"
    "$GM_BIN" -vulkan -fullscreen 0 -asteroids 200000 -benchmark 1 -close 1
    "$GM_BIN" -opengl -fullscreen 0 -asteroids 200000 -benchmark 1 -close 1
    # DirectX on Linux goes through DXVK->Vulkan; native Linux has no -d3d* path.

Notes:
 * Per design §2.1 routing, on Linux pick -vulkan (Venus path) or -opengl
   (VirGL path); do NOT cross-translate.
 * Useful flags (see any run_*.sh header): -asteroids N (fix object count for
   cross-run consistency), -count N (passes), -times FILE (per-frame times),
   -image FILE (screenshot), -vsync 0, -width/-height.
 * GravityMark is GPU-bound (CPU nearly idle) — interpret it separately from
   Basemark GPU's mixed CPU/GPU workload.
 * Normalize frame metrics via MangoHud for cross-tool consistency,
   not GravityMark's self-reported FPS.

$(print_gpu_probe_hint)
EOF
