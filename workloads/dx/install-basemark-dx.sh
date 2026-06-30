#!/usr/bin/env bash
#
# install-basemark-dx.sh — Windows Basemark GPU for the DirectX path.
#
# Basemark GPU's Linux build has only GL/Vulkan (no DX). Its WINDOWS build adds
# DirectX 12, so to get a DX L2 number on Linux per design §2.1 we install the
# Windows build into the Proton prefix and run it through VKD3D-Proton -> Vulkan.
#
# Distribution: Basemark ships Windows as an INSTALLER .exe (not a portable exe
# or msi), so unlike GravityMark we can't just unpack it offline. We run the
# installer inside the Proton prefix; the app then lives under
#   <DX_PREFIX>/drive_c/Program Files/Basemark/...
#
# Requires the DX runtime first (install-dx-runtime.sh). Identical on
# native-linux and the Linux guest. Run as your normal user.
#
# Same Basemark caveats as the Linux build (design §4/§6): GUI-driven, mandatory
# online (uploads to Power Board — guest needs network), AMD+RADV crashes at
# High/4K (use Medium), non-commercial license.
#
# Env overrides:
#   BMK_VERSION  Basemark GPU version (default 1.2.3)
#   BMK_EXE_URL  full Windows installer URL (default derived)
#   DX_PREFIX    wine prefix (default workloads/dx/prefix)
#   BMK_SILENT=1 attempt a silent install (installer-dependent; may be ignored)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

BMK_VERSION="${BMK_VERSION:-1.2.3}"
BMK_EXE="BasemarkGPU-windows-x64-${BMK_VERSION}.exe"
BMK_EXE_URL="${BMK_EXE_URL:-https://cdn.downloads.basemark.com/${BMK_EXE}}"

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DX_PREFIX="${DX_PREFIX:-$LAYER_DIR/prefix}"
EXE_CACHE="$WL_CACHE/$BMK_EXE"

log_info "==> Installing DX workload: Windows Basemark GPU ${BMK_VERSION}"

apt_install curl
need_cmd umu-run   # DX runtime must be installed first

if [[ ! -d "$DX_PREFIX" ]]; then
  log_err "Proton prefix not found: $DX_PREFIX"
  log_err "Run the DX runtime installer first: $LAYER_DIR/install-dx-runtime.sh"
  exit 1
fi

download "$BMK_EXE_URL" "$EXE_CACHE"

log_info "==> Running the Windows installer inside the Proton prefix"
log_info "    (a GUI installer may appear; complete it, or set BMK_SILENT=1)"
EXE_ABS="$(cd "$(dirname "$EXE_CACHE")" && pwd)/$(basename "$EXE_CACHE")"

INSTALL_ARGS=()
[[ "${BMK_SILENT:-0}" == "1" ]] && INSTALL_ARGS+=( /S )   # NSIS-style silent; ignored otherwise

WINEPREFIX="$DX_PREFIX" GAMEID="umu-default" STORE="none" \
  umu-run "$EXE_ABS" "${INSTALL_ARGS[@]}" || log_warn "installer returned non-zero"

# Find the installed Basemark launcher exe in the prefix.
BMK_INSTALLED="$(find "$DX_PREFIX/drive_c" -type f -iname 'basemark*gpu*.exe' 2>/dev/null | head -n1)"
[[ -z "$BMK_INSTALLED" ]] && BMK_INSTALLED="$(find "$DX_PREFIX/drive_c" -type f -iname 'basemark*.exe' 2>/dev/null | grep -vi 'unins' | head -n1)"

if [[ -z "$BMK_INSTALLED" ]]; then
  log_warn "Could not auto-locate the installed Basemark exe under $DX_PREFIX/drive_c"
  log_warn "After completing the installer, find it with:"
  log_warn "  find '$DX_PREFIX/drive_c' -iname 'basemark*.exe'"
else
  log_info "==> Basemark (Windows) installed:"
  log_info "    exe : $BMK_INSTALLED"
fi

cat <<EOF

Done. Windows Basemark GPU ${BMK_VERSION} installed into the Proton prefix:
    $DX_PREFIX

Run it (DirectX 12 -> VKD3D-Proton -> Vulkan) with:
    $LAYER_DIR/run-dx.sh "${BMK_INSTALLED:-<prefix>/drive_c/.../BasemarkGPU.exe}"

    # With unified frame capture (design §3):
    $LAYER_DIR/run-dx.sh --mangohud "${BMK_INSTALLED:-<...>/BasemarkGPU.exe}"

Caveats (same as the Linux build — design §4/§6):
 * GUI-driven; the free build has no end-to-end CLI automation. Pick DirectX 12
   in the launcher to exercise the VKD3D-Proton path.
 * MANDATORY ONLINE: uploads to the Basemark Power Board; the guest needs network.
 * AMD + RADV crashes at High/4K — use MEDIUM quality, non-4K resolution.
 * Non-commercial license; don't publish results on ad-supported sites.
EOF
