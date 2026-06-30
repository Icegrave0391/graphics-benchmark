#!/usr/bin/env bash
#
# common.sh — shared helpers for the workload install scripts.
#
# Workloads are the benchmark TOOLS themselves (not the environments). The same
# install scripts run on BOTH targets we currently support:
#
#   * native-linux  — bare-metal Ubuntu 24.04 host, run directly.
#   * guest-linux   — the Ubuntu 24.04 guest VM (push the repo in and run there,
#                     or run over ssh-vm.sh -- <cmd>); identical OS, identical
#                     install. There is nothing virtualization-specific here.
#
# Both are Ubuntu 24.04 on AMD/Mesa, so one set of scripts covers them. Each
# tool installs UNDER its own workloads/<layer>/ directory (self-contained,
# git-ignored), or via apt for the open-source ones. Scripts are idempotent.
#
# Convention: a layer install script sources this file, then uses the helpers
# (log_*, need_cmd, download, makeself_extract, ...). Run as a normal user;
# helpers that need root call sudo themselves.

set -euo pipefail

# --- repo paths --------------------------------------------------------------
_WL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORKLOADS_DIR="$(cd "$_WL_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$WORKLOADS_DIR/.." && pwd)"

# Where downloaded installers/tarballs are cached so re-runs don't re-download.
# git-ignored (see .gitignore). Override with WL_CACHE.
WL_CACHE="${WL_CACHE:-$WORKLOADS_DIR/.cache}"

# WL_DOWNLOAD_ONLY=1: only download + extract the self-contained payloads; skip
# every system-level step (apt, dpkg, SUID fixes). Used when provisioning a guest
# from the host — the host stays clean and the apt/dpkg/sandbox bits are handled
# by the guest's cloud-init instead. It implies WL_SKIP_APT (which all the
# system-touching blocks already gate on).
if [[ "${WL_DOWNLOAD_ONLY:-0}" == "1" ]]; then
  WL_SKIP_APT=1
fi

# --- pretty logging ----------------------------------------------------------
# Mirror the colours used by environments/guest/linux/.env so output is uniform.
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_err()  { echo -e "${RED}$1${NC}" >&2; }

# --- guards ------------------------------------------------------------------
# Workload installs build/extract as the normal user and only sudo for system
# package installs. Running the whole script as root makes the extracted files
# root-owned, so refuse it (matches the spirit of 40-muvm.sh).
refuse_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    log_err "Run this as your normal user, NOT root/sudo."
    log_err "It extracts tools into workloads/ (must stay user-owned) and"
    log_err "sudo's only for apt steps."
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log_err "Required command '$1' not found. Install it first (e.g. apt-get install $1)."
    exit 1
  }
}

# apt_install <pkg...> — install packages, no-op if already present.
# Set WL_SKIP_APT=1 to skip entirely (e.g. when the deps are known-present and
# you don't want a sudo prompt while iterating on download/extract).
apt_install() {
  if [[ "${WL_SKIP_APT:-0}" == "1" ]]; then
    log_warn "==> WL_SKIP_APT=1, skipping apt-get install: $*"
    return 0
  fi
  log_info "==> apt-get install: $*"
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends "$@"
}

# --- download ----------------------------------------------------------------
# download <url> <dest> — fetch to dest (cached). Resumes partials, verifies the
# file is non-trivially sized. Uses curl or wget, whichever exists.
download() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]]; then
    log_info "==> cached: $dest"
    return 0
  fi
  log_info "==> downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -C - -o "$dest.part" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -c -O "$dest.part" "$url"
  else
    log_err "Neither curl nor wget available to download $url"
    exit 1
  fi
  mv "$dest.part" "$dest"
}

# --- makeself extract --------------------------------------------------------
# makeself_extract <run_file> <target_dir> — extract a Makeself self-installer
# WITHOUT running its embedded script OR its interactive license prompt.
#
# `--noexec` still shows the EULA and blocks on a y/n confirm (it just hangs
# forever in a non-interactive shell). The clean path is `--tar`, which exposes
# the embedded archive directly through tar and bypasses the license/script
# logic entirely. The GravityMark payload sits at the archive root (run_*.sh,
# bin/, data.zip, ...), so we extract straight into target_dir.
makeself_extract() {
  local run="$1" target="$2"
  need_cmd bash
  need_cmd tar
  log_info "==> extracting $(basename "$run") -> $target"
  rm -rf "$target"
  mkdir -p "$target"
  # makeself feeds the embedded data to `tar <args>`; use plain `xf` (NOT `f -`/
  # stdin) with -C to extract into the target dir.
  bash "$run" --tar xf -C "$target" >/dev/null
  # The archive stores files mode 0600/0700 (owner-only). Make them group/other
  # readable+executable so a different user (e.g. in the guest) can run them.
  chmod -R u+rwX,go+rX "$target"
}

# --- tarball extract ---------------------------------------------------------
# tar_extract <tar.gz> <target_dir> — idempotent extract. Skips if target already
# looks populated (a non-empty dir), so re-runs are cheap.
tar_extract() {
  local tarball="$1" target="$2"
  need_cmd tar
  if [[ -d "$target" ]] && [[ -n "$(ls -A "$target" 2>/dev/null)" ]]; then
    log_info "==> already extracted: $target"
    return 0
  fi
  log_info "==> extracting $(basename "$tarball") -> $target"
  rm -rf "$target"
  mkdir -p "$target"
  tar -xf "$tarball" -C "$target"
}

# --- gpu sanity --------------------------------------------------------------
# Print how to confirm the GPU path resolved to the real AMD device (not
# llvmpipe). Same probe regardless of native vs guest.
print_gpu_probe_hint() {
  cat <<'EOF'
Verify the GPU path before trusting numbers (must be AMD, not llvmpipe):
    vulkaninfo --summary | grep -E 'deviceName|driverName'
    glxinfo -B | grep -E 'OpenGL renderer|Device'
EOF
}
