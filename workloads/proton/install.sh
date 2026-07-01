#!/usr/bin/env bash
#
# install.sh — shared DirectX-on-Linux runtime (umu-launcher + Proton).
#
# DirectX under Linux/virtualization is NOT native: it goes
# DXVK/VKD3D-Proton -> Vulkan -> (RADV | venus | native ctx). On venus-linux the
# translated Vulkan runs on the host through Venus, so a DX benchmark exercises
# the same Venus transport as a native Vulkan workload.
#
# This is a SHARED runtime used by the per-workload DX variants:
#   workloads/gravitymark/dx/   (Windows GravityMark, D3D11/D3D12)
#   workloads/basemark-gpu/dx/  (Windows Basemark GPU, D3D12)
#
# Components:
#   * umu-launcher — Valve's Steam Linux Runtime + a `umu-run` wrapper that runs
#     a Windows .exe through Proton WITHOUT Steam. Installed from the project's
#     precompiled Ubuntu-noble .debs (zero source build).
#   * Proton (UMU-Proton = Valve's official Proton + umu compat) — bundles Wine
#     + DXVK + VKD3D-Proton. umu-run auto-downloads it on first run to
#     ~/.local/share/umu (and the Steam Runtime it needs).
#
# This installer installs umu-launcher, creates the shared wine prefix, and
# (optionally) primes the runtime by doing one throwaway run so the big
# Proton/runtime download happens now, not mid-benchmark. It records the resolved
# Proton / DXVK / VKD3D versions into versions.txt for run metadata.
#
# Identical on native-linux and the Linux guest (same Ubuntu 24.04). The guest
# must have network access for the first run (QEMU user-net provides it).
#
# Run as your normal user (NOT root). Env overrides:
#   UMU_VERSION   umu-launcher release tag (default 1.4.0)
#   UMU_PROTON_VERSION  UMU-Proton release to cache/install (default 10.0-4)
#   PROTONPATH    specific Proton directory (default ~/.local/share/umu/compatibilitytools/UMU-Proton)
#   PROTON_PREFIX wine prefix to create (default workloads/proton/prefix)
#   WL_NO_PRIME=1 skip the priming run (download Proton lazily on first use)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

UMU_VERSION="${UMU_VERSION:-1.4.0}"
UMU_PROTON_VERSION="${UMU_PROTON_VERSION:-10.0-4}"
LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROTON_PREFIX="${PROTON_PREFIX:-$LAYER_DIR/prefix}"
VERSIONS_FILE="$LAYER_DIR/versions.txt"

UMU_BASE="https://github.com/Open-Wine-Components/umu-launcher/releases/download/${UMU_VERSION}"
UMU_DEB1="python3-umu-launcher_${UMU_VERSION}-1_amd64_ubuntu-noble.deb"
UMU_DEB2="umu-launcher_${UMU_VERSION}-1_all_ubuntu-noble.deb"

UMU_PROTON_TAG="UMU-Proton-${UMU_PROTON_VERSION}"
UMU_PROTON_TGZ="${UMU_PROTON_TAG}.tar.gz"
UMU_PROTON_BASE="https://github.com/Open-Wine-Components/umu-proton/releases/download/${UMU_PROTON_TAG}"
UMU_COMPAT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/umu/compatibilitytools"
DEFAULT_PROTONPATH="$UMU_COMPAT_DIR/UMU-Proton"

log_info "==> Installing DirectX runtime: umu-launcher ${UMU_VERSION} + Proton"

# Add arch
sudo dpkg --add-architecture i386

# Base deps. umu pulls the Steam Runtime container; it needs these at runtime.
apt_install \
  python3 python3-xlib python3-filelock \
  libvulkan1 vulkan-tools mesa-vulkan-drivers \
  curl ca-certificates

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

if ! command -v umu-run >/dev/null 2>&1; then
  if [[ "${WL_DOWNLOAD_ONLY:-0}" == "1" ]]; then
    log_warn "==> umu-run not installed (download-only). debs cached in $WL_CACHE."
    exit 0
  fi
  log_err "umu-run not on PATH after install"; exit 1
fi

log_info "==> Ensuring UMU-Proton ${UMU_PROTON_VERSION} is cached locally"
if [[ ! -d "$UMU_COMPAT_DIR/UMU-Proton" && ! -d "$UMU_COMPAT_DIR/$UMU_PROTON_TAG" ]]; then
  download "$UMU_PROTON_BASE/$UMU_PROTON_TGZ" "$WL_CACHE/$UMU_PROTON_TGZ"
  mkdir -p "$UMU_COMPAT_DIR"
  tmp_extract="$(mktemp -d)"
  trap 'rm -rf "$tmp_extract"' EXIT
  tar -xf "$WL_CACHE/$UMU_PROTON_TGZ" -C "$tmp_extract"
  proton_root="$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$proton_root" ]] || { log_err "UMU-Proton tarball did not contain a directory"; exit 1; }
  rm -rf "$UMU_COMPAT_DIR/UMU-Proton" "$UMU_COMPAT_DIR/$UMU_PROTON_TAG"
  mv "$proton_root" "$UMU_COMPAT_DIR/UMU-Proton"
else
  log_info "==> UMU-Proton already installed under $UMU_COMPAT_DIR"
fi

export PROTONPATH="${PROTONPATH:-$DEFAULT_PROTONPATH}"

mkdir -p "$PROTON_PREFIX"

if [[ "${WL_NO_PRIME:-0}" == "1" ]]; then
  log_warn "==> WL_NO_PRIME=1: skipping prime; Proton downloads on first real run"
else
  log_info "==> Priming Proton/runtime (first download; needs network)..."
  WINEPREFIX="$PROTON_PREFIX" GAMEID="umu-default" STORE="none" \
    PROTONPATH="$PROTONPATH" \
    umu-run wineboot --init || log_warn "prime run returned non-zero (often OK)"
fi

log_info "==> Recording Proton / DXVK / VKD3D versions -> $VERSIONS_FILE"
{
  echo "# DX runtime versions (auto-recorded $(date -u +%FT%TZ))"
  echo "umu_launcher=${UMU_VERSION}"
  echo "umu_proton=${UMU_PROTON_VERSION}"
  PROTON_DIR="$(find "$HOME/.local/share" -maxdepth 3 -type f -name version 2>/dev/null \
                  -path '*roton*' | head -n1)"
  if [[ -n "$PROTON_DIR" ]]; then
    echo "proton_dir=$(dirname "$PROTON_DIR")"
    echo "proton_version=$(cat "$PROTON_DIR" 2>/dev/null)"
  else
    echo "proton_version=unknown (not downloaded yet; run a benchmark once)"
  fi
  for dll in d3d11 dxgi d3d12 d3d12core; do
    f="$(find "$PROTON_PREFIX" -name "${dll}.dll" 2>/dev/null | head -n1)"
    [[ -n "$f" ]] && echo "dll_${dll}=$f"
  done
} > "$VERSIONS_FILE"

cat <<EOF

Done. umu-launcher ${UMU_VERSION} installed; Proton via UMU-Proton (official).
Shared wine prefix: $PROTON_PREFIX

Next, install a DX workload:
    workloads/gravitymark/dx/install.sh    # Windows GravityMark (D3D11/D3D12)
    workloads/basemark-gpu/dx/install.sh   # Windows Basemark GPU (D3D12)

Then run it with each workload's dx/run.sh. On venus-linux the DX->Vulkan output
runs on the host through Venus (start the VM with the default RADV host ICD).

Recorded runtime versions: $VERSIONS_FILE
(Re-run this script after the first benchmark to fill in the Proton version if it
shows 'unknown'.)
EOF
