#!/usr/bin/env bash
#
# install-gravitymark-dx.sh — Windows GravityMark for the DirectX path.
#
# The LINUX GravityMark build has no DirectX backend (DX is a Windows API). To
# measure DX on Linux per design §2.1, we take the WINDOWS GravityMark build and
# run it through Proton (DXVK/VKD3D -> Vulkan) via run-dx.sh. Same tool as the
# L1 Vulkan/OpenGL runs, so DX numbers are directly comparable to them.
#
# Distribution: Tellusim ships Windows as an .msi (precompiled). We extract the
# payload with msiextract (msitools) — no Wine needed just to unpack — to get
# GravityMark.exe + its DLLs/data. Then run-dx.sh launches it under Proton with
# -d3d11 or -d3d12.
#
# Identical on native-linux and the Linux guest. Run as your normal user.
#
# Env overrides:
#   GM_VERSION  GravityMark version (default 1.89)
#   GM_MSI_URL  full .msi URL (default derived from GM_VERSION)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

GM_VERSION="${GM_VERSION:-1.89}"
GM_MSI="GravityMark_${GM_VERSION}.msi"
GM_MSI_URL="${GM_MSI_URL:-https://tellusim.com/download/${GM_MSI}}"

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$LAYER_DIR/GravityMark-win"
MSI_CACHE="$WL_CACHE/$GM_MSI"

log_info "==> Installing DX workload: Windows GravityMark ${GM_VERSION}"

# msitools provides msiextract to unpack the .msi without Wine.
apt_install msitools curl

download "$GM_MSI_URL" "$MSI_CACHE"

log_info "==> extracting $GM_MSI -> $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
( cd "$INSTALL_DIR" && msiextract "$MSI_CACHE" >/dev/null )

# Locate GravityMark.exe in the extracted tree (msi lays out a Program Files-ish path).
GM_EXE="$(find "$INSTALL_DIR" -type f -iname 'GravityMark.exe' 2>/dev/null | head -n1)"
if [[ -z "$GM_EXE" ]]; then
  log_err "GravityMark.exe not found under $INSTALL_DIR"
  log_err "Inspect: find '$INSTALL_DIR' -iname '*.exe'"
  exit 1
fi

log_info "==> GravityMark (Windows) installed:"
log_info "    exe : $GM_EXE"

cat <<EOF

Done. Windows GravityMark ${GM_VERSION} extracted under:
    $INSTALL_DIR

Run the DirectX path through Proton (DXVK for D3D11, VKD3D-Proton for D3D12).
Make sure the DX runtime is installed first:
    $LAYER_DIR/install-dx-runtime.sh

Then:
    # D3D11 (-> DXVK -> Vulkan):
    $LAYER_DIR/run-dx.sh "$GM_EXE" -d3d11 -fullscreen 0 -asteroids 200000 -benchmark 1 -close 1

    # D3D12 (-> VKD3D-Proton -> Vulkan):
    $LAYER_DIR/run-dx.sh "$GM_EXE" -d3d12 -fullscreen 0 -asteroids 200000 -benchmark 1 -close 1

    # With unified frame capture (recommended, design §3):
    $LAYER_DIR/run-dx.sh --mangohud "$GM_EXE" -d3d11 -asteroids 200000 -benchmark 1 -close 1

Notes:
 * GravityMark Windows CLI matches the Linux one: -d3d11 / -d3d12 select the API
   (instead of -vulkan/-opengl), plus -benchmark 1 / -close 1 / -asteroids N /
   -times FILE. Fix -asteroids across runs for comparability.
 * This is the SAME workload as the Linux L1 Vulkan/GL runs, so its DX-via-DXVK
   number is directly comparable to native Vulkan on the same box.
EOF
