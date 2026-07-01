#!/usr/bin/env bash
#
# install.sh — Windows GravityMark for the DirectX-via-Proton path.
#
# The Linux GravityMark build has no DirectX backend (DX is a Windows API). To
# measure DX on Linux (e.g. on venus-linux: DX -> DXVK/VKD3D -> Vulkan -> Venus),
# we take the WINDOWS GravityMark build and run it through Proton. It is the same
# benchmark as the native Linux GravityMark, so its DX number is comparable to
# the native Vulkan run on the same box.
#
# Distribution: Tellusim ships Windows as an .msi (precompiled). We extract the
# payload with msiextract (msitools) — no Wine needed to unpack — to get
# GravityMark.exe + its DLLs/data. Then run.sh launches it under Proton with
# -direct3d11 or -direct3d12.
#
# Requires the shared Proton runtime first:  workloads/proton/install.sh
# Identical on native-linux and the Linux guest. Run as your normal user.
#
# Env overrides:
#   GM_VERSION  GravityMark version (default 1.89)
#   GM_MSI_URL  full .msi URL (default derived from GM_VERSION)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../lib" && pwd)/common.sh"

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

Install the shared Proton runtime first if you haven't:
    workloads/proton/install.sh

Run the DirectX path (DXVK for D3D11, VKD3D-Proton for D3D12):
    $LAYER_DIR/run.sh --d3d11
    $LAYER_DIR/run.sh --d3d12
    $LAYER_DIR/run.sh --d3d11 --mangohud     # unified frame capture

On venus-linux this DX->Vulkan output runs on the host through Venus (start the
VM with the default RADV host ICD). GravityMark Windows CLI uses -direct3d11 / -direct3d12
(instead of -vulkan/-opengl), plus -benchmark 1 / -close 1 / -asteroids N.
EOF
