#!/usr/bin/env bash
#
# install.sh — Windows Basemark GPU for the DirectX-via-Proton path.
#
# Basemark GPU's Linux build has only GL/Vulkan (no DX). Its WINDOWS build adds
# DirectX 12, so to measure DX on Linux (e.g. venus-linux: D3D12 -> VKD3D-Proton
# -> Vulkan -> Venus) we install the Windows build into the shared Proton prefix
# and run it there.
#
# Distribution: Basemark ships Windows as an INSTALLER .exe (not portable / not
# msi), so unlike GravityMark we can't unpack it offline. We run the installer
# inside the Proton prefix; the app then lives under
#   <PROTON_PREFIX>/drive_c/Program Files/Basemark/...
#
# Requires the shared Proton runtime first: workloads/proton/install.sh
# Identical on native-linux and the Linux guest. Run as your normal user.
#
# Env overrides:
#   BMK_VERSION    Basemark GPU version (default 1.2.3)
#   BMK_EXE_URL    full Windows installer URL (default derived)
#   PROTON_PREFIX  wine prefix (default workloads/proton/prefix)
#   BMK_SILENT=1   attempt a silent install (installer-dependent; may be ignored)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../lib" && pwd)/common.sh"

refuse_root

BMK_VERSION="${BMK_VERSION:-1.2.3}"
BMK_EXE="BasemarkGPU-windows-x64-${BMK_VERSION}.exe"
BMK_EXE_URL="${BMK_EXE_URL:-https://cdn.downloads.basemark.com/${BMK_EXE}}"

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROTON_DIR="$(cd "$LAYER_DIR/../../proton" && pwd)"
PROTON_PREFIX="${PROTON_PREFIX:-$PROTON_DIR/prefix}"
PROTON_RUN="$PROTON_DIR/run.sh"
EXE_CACHE="$WL_CACHE/$BMK_EXE"

log_info "==> Installing DX workload: Windows Basemark GPU ${BMK_VERSION}"

apt_install curl

download "$BMK_EXE_URL" "$EXE_CACHE"

if [[ "${WL_DOWNLOAD_ONLY:-0}" == "1" ]]; then
  log_warn "==> WL_DOWNLOAD_ONLY=1: cached installer only; run in-guest to install into Proton prefix."
  exit 0
fi

need_cmd umu-run
[[ -x "$PROTON_RUN" ]] || { log_err "shared Proton runner missing: $PROTON_RUN (run workloads/proton/install.sh)"; exit 1; }
if [[ ! -d "$PROTON_PREFIX" ]]; then
  log_err "Proton prefix not found: $PROTON_PREFIX"
  log_err "Run the shared Proton runtime installer first: workloads/proton/install.sh"
  exit 1
fi

log_info "==> Running the Windows installer inside the Proton prefix"
log_info "    (a GUI installer may appear; complete it, or set BMK_SILENT=1)"
EXE_ABS="$(cd "$(dirname "$EXE_CACHE")" && pwd)/$(basename "$EXE_CACHE")"

INSTALL_ARGS=()
[[ "${BMK_SILENT:-0}" == "1" ]] && INSTALL_ARGS+=( /S )

"$PROTON_RUN" -- "$EXE_ABS" "${INSTALL_ARGS[@]}" || log_warn "installer returned non-zero"

BMK_INSTALLED="$(find "$PROTON_PREFIX/drive_c" -type f -iname 'basemark*gpu*.exe' 2>/dev/null | head -n1)"
[[ -z "$BMK_INSTALLED" ]] && BMK_INSTALLED="$(find "$PROTON_PREFIX/drive_c" -type f -iname 'basemark*.exe' 2>/dev/null | grep -vi 'unins' | head -n1)"

if [[ -z "$BMK_INSTALLED" ]]; then
  log_warn "Could not auto-locate the installed Basemark exe under $PROTON_PREFIX/drive_c"
  log_warn "After completing the installer, find it with:"
  log_warn "  find '$PROTON_PREFIX/drive_c' -iname 'basemark*.exe'"
else
  log_info "==> Basemark (Windows) installed:"
  log_info "    exe : $BMK_INSTALLED"
fi

cat <<EOF

Done. Windows Basemark GPU ${BMK_VERSION} installed into the Proton prefix:
    $PROTON_PREFIX

Run it (DirectX 12 -> VKD3D-Proton -> Vulkan) with:
    $(dirname "$0")/run.sh
    $(dirname "$0")/run.sh --mangohud       # unified frame capture

Caveats (same as the Linux build):
 * GUI-driven; the free build has no end-to-end CLI automation. Pick DirectX 12
   in the launcher to exercise the VKD3D-Proton path.
 * MANDATORY ONLINE: uploads to the Basemark Power Board; the guest needs network.
 * AMD + RADV crashes at High/4K — use MEDIUM quality, non-4K resolution.
 * Non-commercial license; don't publish results on ad-supported sites.
EOF
