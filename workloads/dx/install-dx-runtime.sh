#!/usr/bin/env bash
#
# install-dx-runtime.sh — DirectX-on-Linux runtime (umu-launcher + Proton).
#
# Per design §2.1, DirectX under Linux/virtualization is NOT native: it goes
# DXVK/VKD3D-Proton -> Vulkan -> (RADV | venus | native ctx). We get a clean,
# version-pinned DX->Vulkan path by using:
#
#   * umu-launcher — Valve's Steam Linux Runtime + a `umu-run` wrapper that runs
#     a Windows .exe through Proton WITHOUT Steam. Installed from the project's
#     precompiled Ubuntu-noble .debs (zero source build).
#   * Proton (UMU-Proton, = Valve's official Proton + umu compat) — bundles Wine
#     + DXVK + VKD3D-Proton. umu-run auto-downloads it on first run to
#     ~/.local/share/umu (and the Steam Runtime it needs).
#
# So this installer just installs umu-launcher and (optionally) "primes" the
# runtime by doing one throwaway run so the big Proton/runtime download happens
# now, not in the middle of your first benchmark. It then records the resolved
# Proton / DXVK / VKD3D versions into versions.txt for the result schema
# (design §3.1 requires dxvk_version / vkd3d_version per run).
#
# Identical on native-linux and the Linux guest (same Ubuntu 24.04). The guest
# must have network access for the first run (QEMU user-net provides it).
#
# Run as your normal user (NOT root). Env overrides:
#   UMU_VERSION       umu-launcher release tag (default 1.4.0)
#   PROTONPATH        specific Proton dir, or "GE-Proton" for latest GE; unset
#                     => UMU-Proton (official Proton). We keep default = official.
#   DX_PREFIX         wine prefix to create (default workloads/dx/prefix)
#   WL_NO_PRIME=1     skip the priming run (download Proton lazily on first use)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

UMU_VERSION="${UMU_VERSION:-1.4.0}"
LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DX_PREFIX="${DX_PREFIX:-$LAYER_DIR/prefix}"
VERSIONS_FILE="$LAYER_DIR/versions.txt"

# umu-launcher's two companion debs for Ubuntu 24.04 (noble), precompiled.
UMU_BASE="https://github.com/Open-Wine-Components/umu-launcher/releases/download/${UMU_VERSION}"
UMU_DEB1="python3-umu-launcher_${UMU_VERSION}-1_amd64_ubuntu-noble.deb"
UMU_DEB2="umu-launcher_${UMU_VERSION}-1_all_ubuntu-noble.deb"

log_info "==> Installing DirectX runtime: umu-launcher ${UMU_VERSION} + Proton"

# Base deps. umu pulls Steam Runtime as a container; it needs these at runtime.
apt_install \
  python3 python3-xlib python3-filelock \
  libvulkan1 vulkan-tools mesa-vulkan-drivers \
  curl ca-certificates

# Install umu-launcher from its precompiled debs unless already present.
if command -v umu-run >/dev/null 2>&1; then
  log_info "==> umu-run already installed: $(command -v umu-run)"
else
  download "$UMU_BASE/$UMU_DEB1" "$WL_CACHE/$UMU_DEB1"
  download "$UMU_BASE/$UMU_DEB2" "$WL_CACHE/$UMU_DEB2"
  if [[ "${WL_SKIP_APT:-0}" == "1" ]]; then
    log_warn "==> WL_SKIP_APT=1, skipping dpkg install of umu debs"
  else
    log_info "==> installing umu-launcher debs"
    sudo apt-get install -y "$WL_CACHE/$UMU_DEB1" "$WL_CACHE/$UMU_DEB2"
  fi
fi

command -v umu-run >/dev/null 2>&1 || { log_err "umu-run not on PATH after install"; exit 1; }

mkdir -p "$DX_PREFIX"

# Prime: do one throwaway run so umu downloads Proton + Steam Runtime now.
# `wineboot` is a tiny Windows builtin; running it forces the full setup.
if [[ "${WL_NO_PRIME:-0}" == "1" ]]; then
  log_warn "==> WL_NO_PRIME=1: skipping prime; Proton downloads on first real run"
else
  log_info "==> Priming Proton/runtime (first download; needs network)..."
  WINEPREFIX="$DX_PREFIX" GAMEID="umu-default" STORE="none" \
    umu-run wineboot --init || log_warn "prime run returned non-zero (often OK)"
fi

# Record resolved versions for the result schema (design §3.1).
log_info "==> Recording Proton / DXVK / VKD3D versions -> $VERSIONS_FILE"
{
  echo "# DX runtime versions (auto-recorded $(date -u +%FT%TZ))"
  echo "umu_launcher=${UMU_VERSION}"
  # Proton lands under ~/.local/share/Steam/compatibilitytools.d or
  # ~/.local/share/umu; find the active one's version file.
  PROTON_DIR="$(find "$HOME/.local/share" -maxdepth 3 -type f -name version 2>/dev/null \
                  -path '*roton*' | head -n1)"
  if [[ -n "$PROTON_DIR" ]]; then
    echo "proton_dir=$(dirname "$PROTON_DIR")"
    echo "proton_version=$(cat "$PROTON_DIR" 2>/dev/null)"
  else
    echo "proton_version=unknown (not downloaded yet; run a benchmark once)"
  fi
  # DXVK / VKD3D dll versions, if the prefix has them installed.
  for dll in d3d11 dxgi d3d12 d3d12core; do
    f="$(find "$DX_PREFIX" -name "${dll}.dll" 2>/dev/null | head -n1)"
    [[ -n "$f" ]] && echo "dll_${dll}=$f"
  done
} > "$VERSIONS_FILE"

cat <<EOF

Done. umu-launcher ${UMU_VERSION} installed; Proton via UMU-Proton (official).

Identical on native-linux and the Linux guest. The wine prefix lives at:
    $DX_PREFIX

Run a Windows DX .exe through this DX->Vulkan path with the wrapper:
    $LAYER_DIR/run-dx.sh /path/to/App.exe [app args...]

The API the app uses (D3D11 via DXVK, D3D12 via VKD3D-Proton) is translated to
Vulkan and executed by RADV (native) / venus (venus-linux) / native ctx (muvm)
— a single clean transport per design §2.1.

Recorded runtime versions: $VERSIONS_FILE
(Re-run this script after the first benchmark to capture the Proton version if
it shows 'unknown'.)
EOF
